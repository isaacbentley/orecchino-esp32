#pragma once
#include "Arduino.h"
enum { WIFI_STA = 1 };
struct MockWiFi { bool mode(int) { return true; } void disconnect() {} };
extern MockWiFi WiFi;
