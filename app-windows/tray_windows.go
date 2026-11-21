// SPDX-License-Identifier: GPL-3.0-or-later

package main

import (
	"fmt"
	"strings"
	"time"
	"unicode/utf16"
	"unsafe"

	"golang.org/x/sys/windows"
)

const (
	trayMessage     = 0x8001
	trayID          = 1
	appIconResource = 2

	trayAdd    = 0
	trayModify = 1
	trayDelete = 2

	trayFlagMessage = 1
	trayFlagIcon    = 2
	trayFlagTip     = 4
	trayFlagInfo    = 16
	trayInfo        = 1
	trayWarning     = 2
)

type notifyIconData struct {
	Size     uint32
	Window   uintptr
	ID       uint32
	Flags    uint32
	Callback uint32
	Icon     uintptr
	Tip      [128]uint16
	State    uint32
	Mask     uint32
	Info     [256]uint16
	Timeout  uint32
	Title    [64]uint16
	InfoKind uint32
	GUID     windows.GUID
	IconInfo uintptr
}

var (
	shellNotify = windows.NewLazySystemDLL("shell32.dll").NewProc("Shell_NotifyIconW")
	user32      = windows.NewLazySystemDLL("user32.dll")
	loadImage   = user32.NewProc("LoadImageW")
	loadIcon    = user32.NewProc("LoadIconW")
	showWindow  = user32.NewProc("ShowWindow")
	focusWindow = user32.NewProc("SetForegroundWindow")
	isIconic    = user32.NewProc("IsIconic")
	comctl      = windows.NewLazySystemDLL("comctl32.dll")
	setSubclass = comctl.NewProc("SetWindowSubclass")
	delSubclass = comctl.NewProc("RemoveWindowSubclass")
	defSubclass = comctl.NewProc("DefSubclassProc")
)

var trayCallback = windows.NewCallback(func(hwnd, message, wParam, lParam, _, _ uintptr) uintptr {
	if message == trayMessage && wParam == trayID {
		switch lParam {
		case 0x0202, 0x0203, 0x0405: // click, double click, balloon click
			if minimized, _, _ := isIconic.Call(hwnd); minimized != 0 {
				_, _, _ = showWindow.Call(hwnd, 9) // SW_RESTORE
			}
			_, _, _ = focusWindow.Call(hwnd)
			return 0
		}
	}
	result, _, _ := defSubclass.Call(hwnd, message, wParam, lParam)
	return result
})

func iconText(dst []uint16, text string) {
	clear(dst)
	text = strings.ReplaceAll(text, "\x00", "")
	encoded := utf16.Encode([]rune(text))
	if len(encoded) >= len(dst) {
		encoded = encoded[:len(dst)-1]
		if c := encoded[len(encoded)-1]; c >= 0xD800 && c <= 0xDBFF {
			encoded = encoded[:len(encoded)-1]
		}
	}
	copy(dst, encoded)
}

func notify(operation uintptr, data *notifyIconData) bool {
	result, _, _ := shellNotify.Call(operation, uintptr(unsafe.Pointer(data)))
	return result != 0
}

// startTray begins monitoring while the desktop window is running.
func startTray(hwnd uintptr, receiver *Receiver, alerts func() []airAlert) func() {
	if setSubclass.Find() != nil || delSubclass.Find() != nil || defSubclass.Find() != nil {
		return func() {}
	}
	subclass, _, _ := setSubclass.Call(hwnd, trayCallback, trayID, 0)
	var module windows.Handle
	_ = windows.GetModuleHandleEx(0, nil, &module)
	icon, _, _ := loadImage.Call(uintptr(module), appIconResource, 1, 16, 16, 0x8000) // IMAGE_ICON, LR_SHARED
	if icon == 0 {
		icon, _, _ = loadIcon.Call(0, 32512) // IDI_APPLICATION
	}
	data := notifyIconData{
		Size: uint32(unsafe.Sizeof(notifyIconData{})), Window: hwnd, ID: trayID, Icon: icon,
		Flags: trayFlagIcon | trayFlagTip,
	}
	if subclass != 0 {
		data.Flags |= trayFlagMessage
		data.Callback = trayMessage
	}
	iconText(data.Tip[:], "Orecchino")
	added := notify(trayAdd, &data)

	stop := make(chan struct{})
	done := make(chan struct{})
	go func() {
		defer close(done)
		ticker := time.NewTicker(2 * time.Second)
		defer ticker.Stop()
		last := make(map[string]time.Time)
		active := make(map[string]bool)
		var queue []airAlert
		var previousTip string
		for {
			select {
			case <-stop:
				return
			case now := <-ticker.C:
				state := receiver.Snapshot()
				current := alerts()
				drones, warnings := 0, 0
				for _, drone := range state.Tracks {
					if !drone.Simulated && !drone.Stale {
						drones++
					}
				}
				for _, alert := range current {
					if !alert.Simulated {
						warnings++
					}
				}
				tip := fmt.Sprintf("Orecchino · %d drone(s) · %d waarschuwing(en)", drones, warnings)
				if tip != previousTip || !added {
					iconText(data.Tip[:], tip)
					added = notify(trayModify, &data) || notify(trayAdd, &data)
					previousTip = tip
				}
				for key, when := range last {
					if now.Sub(when) >= 5*time.Minute {
						delete(last, key)
					}
				}
				nextActive := make(map[string]bool, len(current))
				for _, alert := range current {
					if alert.Simulated {
						continue
					}
					key := trayAlertKey(alert)
					if !active[key] && !nextActive[key] && !alert.Held && last[key].IsZero() {
						queue = append(queue, alert)
					}
					nextActive[key] = true
				}
				active = nextActive
				for len(queue) > 0 && added {
					alert := queue[0]
					key := trayAlertKey(alert)
					if !active[key] {
						queue = queue[1:]
						continue
					}
					balloon := data
					balloon.Flags = trayFlagInfo
					balloon.InfoKind = trayInfo
					if alert.Level == "warning" {
						balloon.InfoKind = trayWarning
					}
					iconText(balloon.Title[:], alert.Action)
					iconText(balloon.Info[:], alert.Summary)
					if notify(trayModify, &balloon) {
						last[key] = now
						queue = queue[1:]
					} else {
						added = false
					}
					break
				}
			}
		}
	}()
	return func() {
		close(stop)
		<-done
		notify(trayDelete, &data)
		if subclass != 0 {
			_, _, _ = delSubclass.Call(hwnd, trayCallback, trayID)
		}
	}
}

func trayAlertKey(alert airAlert) string {
	if alert.DroneID == "" {
		return alert.Kind + "|" + alert.Hex
	}
	return alert.DroneID + "|" + alert.Hex
}
