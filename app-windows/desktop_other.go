//go:build !windows

// SPDX-License-Identifier: GPL-3.0-or-later

package main

import (
	"context"
	"errors"
	"log"
	"os"
)

func defaultDataRoot() (string, error) {
	return os.UserConfigDir()
}

func desktopWindowVisible() bool { return true }

func showDesktop(_ context.Context, _, _ string, _ *Receiver, _ func() []airAlert) error {
	return errors.New("het desktopvenster is beschikbaar op Windows. Gebruik -preview om de interface in een browser te testen")
}

func showStartupError(err error) {
	log.Print(err)
}
