// Orecchino for Windows, adapted from the Orecchino project by Isaac Bentley.
// SPDX-License-Identifier: GPL-3.0-or-later

package main

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"log"
	"math"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

//go:embed ui LICENSE
var files embed.FS

type settings struct {
	Lat  *float64 `json:"lat"`
	Lon  *float64 `json:"lon"`
	Port string   `json:"port,omitempty"`
}

func (s settings) location() *GeoPoint {
	if s.Lat == nil || s.Lon == nil {
		return nil
	}
	return &GeoPoint{Lat: *s.Lat, Lon: *s.Lon}
}

type app struct {
	receiver *Receiver
	dataDir  string
	portMu   sync.Mutex
	mu       sync.Mutex
	settings settings
}

func (a *app) currentSettings() settings {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.settings
}

func (a *app) changeSettings(change func(*settings)) error {
	a.mu.Lock()
	defer a.mu.Unlock()

	next := a.settings
	change(&next)
	data, err := json.MarshalIndent(next, "", "  ")
	if err != nil {
		return err
	}
	f, err := os.CreateTemp(a.dataDir, ".settings-*.json")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	_, writeErr := f.Write(data)
	closeErr := f.Close()
	if err := errors.Join(writeErr, closeErr); err != nil {
		return err
	}
	if err := os.Rename(f.Name(), filepath.Join(a.dataDir, "settings.json")); err != nil {
		return err
	}
	a.settings = next
	return nil
}

func (a *app) location() *GeoPoint {
	return a.currentSettings().location()
}

func (a *app) register(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/state", func(w http.ResponseWriter, _ *http.Request) {
		replyJSON(w, http.StatusOK, map[string]any{
			"receiver": a.receiver.Snapshot(),
			"settings": a.currentSettings(),
		})
	})
	mux.HandleFunc("GET /api/ports", func(w http.ResponseWriter, _ *http.Request) {
		ports, err := a.receiver.Ports()
		if err != nil {
			replyError(w, http.StatusServiceUnavailable, err)
			return
		}
		if ports == nil {
			ports = []string{}
		}
		replyJSON(w, http.StatusOK, map[string]any{"ports": ports})
	})
	mux.HandleFunc("POST /api/connect", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Port string `json:"port"`
		}
		if !readRequest(w, r, &body) {
			return
		}
		body.Port = strings.TrimSpace(body.Port)
		if body.Port == "" {
			body.Port = "auto"
		}
		a.portMu.Lock()
		defer a.portMu.Unlock()
		previous := a.currentSettings().Port
		if err := a.receiver.Connect(body.Port); err != nil {
			replyError(w, http.StatusBadRequest, err)
			return
		}
		if err := a.changeSettings(func(s *settings) { s.Port = body.Port }); err != nil {
			if previous == "off" {
				a.receiver.Disconnect()
			} else {
				_ = a.receiver.Connect(previous)
			}
			replyError(w, http.StatusInternalServerError, fmt.Errorf("COM-poort opslaan: %w", err))
			return
		}
		replyJSON(w, http.StatusOK, a.receiver.Snapshot())
	})
	mux.HandleFunc("POST /api/disconnect", func(w http.ResponseWriter, _ *http.Request) {
		a.portMu.Lock()
		defer a.portMu.Unlock()
		if err := a.changeSettings(func(s *settings) { s.Port = "off" }); err != nil {
			replyError(w, http.StatusInternalServerError, fmt.Errorf("instelling opslaan: %w", err))
			return
		}
		a.receiver.Disconnect()
		replyJSON(w, http.StatusOK, a.receiver.Snapshot())
	})
	mux.HandleFunc("POST /api/demo", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Enabled bool `json:"enabled"`
		}
		if !readRequest(w, r, &body) {
			return
		}
		a.receiver.SetDemo(body.Enabled)
		replyJSON(w, http.StatusOK, a.receiver.Snapshot())
	})
	mux.HandleFunc("POST /api/location", func(w http.ResponseWriter, r *http.Request) {
		var body settings
		if !readRequest(w, r, &body) {
			return
		}
		if (body.Lat == nil) != (body.Lon == nil) ||
			(body.Lat != nil && (!validCoordinate(*body.Lat, 90) || !validCoordinate(*body.Lon, 180))) {
			replyError(w, http.StatusBadRequest, errors.New("geef een geldige breedte- en lengtegraad op"))
			return
		}
		if err := a.changeSettings(func(s *settings) { s.Lat, s.Lon = body.Lat, body.Lon }); err != nil {
			replyError(w, http.StatusInternalServerError, fmt.Errorf("locatie opslaan: %w", err))
			return
		}
		replyJSON(w, http.StatusOK, a.currentSettings())
	})
	mux.HandleFunc("GET /LICENSE", func(w http.ResponseWriter, _ *http.Request) {
		license, _ := files.ReadFile("LICENSE")
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write(license)
	})
	ui, err := fs.Sub(files, "ui")
	if err != nil {
		panic(err)
	}
	mux.Handle("GET /", http.FileServerFS(ui))
}

func validCoordinate(value, max float64) bool {
	return !math.IsNaN(value) && math.Abs(value) <= max
}

func (a *app) syncLocation(ctx context.Context) {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()

	var lastSession uint64
	var lastPoint *GeoPoint
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			state := a.receiver.Snapshot()
			if state.Status != "receiving" {
				continue
			}
			point := a.location()
			if point == nil || (lastSession == state.Session && lastPoint != nil && *lastPoint == *point) {
				continue
			}
			command := map[string]any{"cmd": "set_home", "lat": point.Lat, "lon": point.Lon, "src": "windows"}
			if a.receiver.SendFor(state.Session, command) == nil {
				lastSession, lastPoint = state.Session, point
			}
		}
	}
}

func replyJSON(w http.ResponseWriter, code int, data any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(data)
}

func replyError(w http.ResponseWriter, code int, err error) {
	replyJSON(w, code, map[string]string{"error": err.Error()})
}

func readRequest(w http.ResponseWriter, r *http.Request, value any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, 16384)
	decoder := json.NewDecoder(r.Body)
	if err := decoder.Decode(value); err != nil {
		replyError(w, http.StatusBadRequest, errors.New("ongeldige JSON-invoer"))
		return false
	}
	if !errors.Is(decoder.Decode(new(any)), io.EOF) {
		replyError(w, http.StatusBadRequest, errors.New("ongeldige JSON-invoer"))
		return false
	}
	return true
}

func localAccess(next http.Handler, host, token string) http.Handler {
	origin := "http://" + host
	cookieName := "orecchino_" + token[:12]
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https://server.arcgisonline.com; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'; object-src 'none'")
		if r.Host != host || (r.Header.Get("Origin") != "" && r.Header.Get("Origin") != origin) {
			replyError(w, http.StatusForbidden, errors.New("open de lokale Orecchino-app"))
			return
		}

		if r.Method == http.MethodGet && r.URL.Path == "/" &&
			subtle.ConstantTimeCompare([]byte(r.URL.Query().Get("start")), []byte(token)) == 1 {
			http.SetCookie(w, &http.Cookie{
				Name: cookieName, Value: token, Path: "/", HttpOnly: true, SameSite: http.SameSiteStrictMode,
				// Removing the cookie on browser shutdown avoids keeping old instance credentials.
			})
			http.Redirect(w, r, "/", http.StatusSeeOther)
			return
		}
		cookie, err := r.Cookie(cookieName)
		if err != nil || subtle.ConstantTimeCompare([]byte(cookie.Value), []byte(token)) != 1 {
			replyError(w, http.StatusUnauthorized, errors.New("open de lokale Orecchino-app"))
			return
		}
		if strings.HasPrefix(r.URL.Path, "/api/") && r.Header.Get("Sec-Fetch-Site") == "cross-site" {
			replyError(w, http.StatusForbidden, errors.New("open de lokale Orecchino-app"))
			return
		}
		next.ServeHTTP(w, r)
	})
}

func run() error {
	preview := flag.Bool("preview", false, "start de lokale interface in een browser")
	demo := flag.Bool("demo", false, "start de simulatie")
	dataDir := flag.String("data-dir", "", "overschrijf de map voor lokale instellingen")
	flag.Parse()

	if *dataDir == "" {
		root, err := defaultDataRoot()
		if err != nil {
			return err
		}
		*dataDir = filepath.Join(root, "Orecchino")
	}
	if err := os.MkdirAll(*dataDir, 0700); err != nil {
		return err
	}
	a := &app{receiver: NewReceiver(), dataDir: *dataDir}
	defer a.receiver.Disconnect()
	if data, err := os.ReadFile(filepath.Join(*dataDir, "settings.json")); err == nil {
		if err := json.Unmarshal(data, &a.settings); err != nil {
			log.Printf("instellingen lezen: %v", err)
			a.settings = settings{}
		}
	}
	if a.settings.Port == "" {
		a.settings.Port = "auto"
	}
	if a.settings.Port != "off" && !*demo {
		if err := a.receiver.Connect(a.settings.Port); err != nil {
			log.Printf("ontvanger openen: %v", err)
			_ = a.receiver.Connect("auto")
		}
	}
	a.receiver.SetDemo(*demo)

	mux := http.NewServeMux()
	a.register(mux)
	registerDevice(mux, a.receiver, *dataDir)
	stopDroneguide := registerDroneguide(mux, *dataDir)
	defer stopDroneguide()
	stopATAK := registerATAK(mux, *dataDir, a.receiver.Snapshot)
	defer stopATAK()
	stopAirspace, currentAlerts := registerAirspace(mux, a.receiver, a.location, *dataDir)
	defer stopAirspace()

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
	defer cancel()
	go a.syncLocation(ctx)

	l, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return err
	}
	var secret [32]byte
	if _, err := rand.Read(secret[:]); err != nil {
		_ = l.Close()
		return err
	}
	token := hex.EncodeToString(secret[:])
	address := l.Addr().String()
	server := &http.Server{
		Handler:           localAccess(mux, address, token),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		IdleTimeout:       30 * time.Second,
		MaxHeaderBytes:    16 * 1024,
	}
	go func() {
		if err := server.Serve(l); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Printf("lokale app-interface: %v", err)
			cancel()
		}
	}()
	defer server.Close()

	url := "http://" + address + "/?start=" + token
	if *preview {
		fmt.Println(url)
		<-ctx.Done()
		return nil
	}
	return showDesktop(ctx, url, *dataDir, a.receiver, currentAlerts)
}

func main() {
	if err := run(); err != nil {
		showStartupError(err)
		os.Exit(1)
	}
}
