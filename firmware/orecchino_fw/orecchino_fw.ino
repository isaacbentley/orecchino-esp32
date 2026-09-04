// orecchino_fw — USB Remote ID receiver dongle.
// Target: Seeed Studio XIAO ESP32-C3 (esp32:esp32:XIAO_ESP32C3)
//
// Headless: everything lives in the shared core (firmware/common/rx_core.h)
// and streams as JSON lines over native USB CDC to the desktop app. This
// sketch is the reference for what a board adds — nothing.
#include <Arduino.h>
#define FW_BOARD "xiao-esp32c3"
#include "../common/rx_core.h"

void setup() {
  // Host lines run to 1.6 KB (TFR polygons, tile chunks) and land in one
  // USB burst; the default CDC ring buffer cannot hold one whole line.
  Serial.setRxBufferSize(4096);
  Serial.begin(115200);
  uint32_t t0 = millis();
  while (!Serial && millis() - t0 < 3000) delay(10);
  rx_begin(nullptr);
}

void loop() {
  rx_tick(millis());
  delay(5);
}
