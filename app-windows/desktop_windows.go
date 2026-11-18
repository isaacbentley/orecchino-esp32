// SPDX-License-Identifier: GPL-3.0-or-later

package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"unsafe"

	webview "github.com/jchv/go-webview2"
	"github.com/jchv/go-webview2/webviewloader"
	"golang.org/x/sys/windows"
)

func defaultDataRoot() (string, error) {
	if root := os.Getenv("LOCALAPPDATA"); root != "" {
		return root, nil
	}
	return os.UserConfigDir()
}

func showDesktop(ctx context.Context, address, dataDir string, receiver *Receiver, alerts func() []airAlert) error {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	version, err := webviewloader.GetInstalledVersion()
	if err != nil {
		return fmt.Errorf("Microsoft Edge WebView2 controleren: %w", err)
	}
	if version == "" {
		return errors.New("installeer Microsoft Edge WebView2 Evergreen Runtime via https://developer.microsoft.com/microsoft-edge/webview2/ en open Orecchino opnieuw")
	}

	window := webview.NewWithOptions(webview.WebViewOptions{
		AutoFocus: true,
		DataPath:  filepath.Join(dataDir, "WebView2"),
		WindowOptions: webview.WindowOptions{
			Title:  "Orecchino",
			Width:  1240,
			Height: 750,
			IconId: appIconResource,
		},
	})
	if window == nil {
		return errors.New("het Orecchino-venster kon niet worden geopend")
	}
	defer window.Destroy()
	window.SetSize(780, 560, webview.HintMin)
	defer startTray(uintptr(window.Window()), receiver, alerts)()
	window.Navigate(address)
	done := make(chan struct{})
	defer close(done)
	go func() {
		select {
		case <-ctx.Done():
			window.Dispatch(window.Destroy)
		case <-done:
		}
	}()
	window.Run()
	return nil
}

func showStartupError(err error) {
	message, _ := windows.UTF16PtrFromString(err.Error())
	title, _ := windows.UTF16PtrFromString("Orecchino")
	proc := windows.NewLazySystemDLL("user32.dll").NewProc("MessageBoxW")
	_, _, _ = proc.Call(0, uintptr(unsafe.Pointer(message)), uintptr(unsafe.Pointer(title)), 0x10)
}
