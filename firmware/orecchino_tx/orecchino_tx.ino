// orecchino_tx — Remote ID test beacon on the Seeed XIAO ESP32-C3.
// Target: esp32:esp32:XIAO_ESP32C3 (PartitionScheme=huge_app)
//
// Headless: the whole transmitter is the shared core
// (firmware/common/tx_core.h); this sketch is the USB stick that runs it.
// Serial commands: s status, go/stop, e emergency toggle, h home, r ring.
#include <Arduino.h>
#include "../common/tx_core.h"

void setup() {
  Serial.begin(115200);
  uint32_t t0 = millis();
  while (!Serial && millis() - t0 < 3000) delay(10);
  tx_begin();
}

void loop() {
  tx_tick(millis());
  delay(2);
}
