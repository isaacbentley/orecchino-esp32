#include "Arduino.h"
#include "WiFi.h"
#include "esp_wifi.h"
#include "NimBLEDevice.h"
uint32_t g_millis = 0; MockSerial Serial; MockESP ESP; MockWiFi WiFi;
std::vector<std::vector<uint8_t>> g_wifi_tx;
std::vector<uint32_t> g_wifi_tx_at;
int g_wifi_tx_refuse = 0;
uint8_t g_wifi_channel = 0;
NimBLEExtAdvertising NimBLEDevice::adv; NimBLEScan NimBLEDevice::scan;
