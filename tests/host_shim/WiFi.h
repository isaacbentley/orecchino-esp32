#pragma once
#include "Arduino.h"
enum { WIFI_STA = 1 };
struct MockWiFi { void mode(int) {} void disconnect() {} };
extern MockWiFi WiFi;
