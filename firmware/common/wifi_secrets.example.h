// Copy to wifi_secrets.h (untracked, in .gitignore: never commit one) to
// give a Wi-Fi board a network to use until one is saved on the device from
// its settings screen. Read by net_sync.h when present.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#define ORECCHINO_WIFI_SSID "your network"
#define ORECCHINO_WIFI_PASS "its password"
