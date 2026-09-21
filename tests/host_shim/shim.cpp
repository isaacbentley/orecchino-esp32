#include "Arduino.h"
#include "WiFi.h"
#include "esp_wifi.h"
#include "NimBLEDevice.h"
uint32_t g_millis = 0; MockSerial Serial; MockESP ESP; MockWiFi WiFi;
std::vector<std::vector<uint8_t>> g_wifi_tx;
NimBLEExtAdvertising NimBLEDevice::adv; NimBLEScan NimBLEDevice::scan;
