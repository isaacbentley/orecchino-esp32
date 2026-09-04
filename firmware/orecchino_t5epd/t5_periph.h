// T5 E-Paper S3 Pro peripherals that live on the I2C bus epdiy owns —
// reached through the ESP-IDF i2c_master bus handle epdiy created, never
// through the Arduino two-wire library (the port cannot carry both drivers).
//
//   * PCA9555 IO expander: epdiy drives its port 1 for the panel; port 0
//     bit 0 is LORA_EN, the 3V3 rail feeding the SX1262 *and* the GPS.
//   * Touch: a Goodix controller — GT911 on some batches, the GT6972P
//     ("Berlin" register map) on others. Probed at boot; one finger is all
//     a slow panel needs (tap and drag-release).
//   * BQ27220 fuel gauge: state of charge, percent.
//   * GPS on UART1 (RX 44 / TX 43): NMEA GGA parsed into the operator
//     position, so the board self-locates in the field without the app.
#pragma once
#include <Arduino.h>

/// Optional pre-init: pulses GT911 RST/INT to latch address 0x5D before epdiy claims GPIO9
void periph_touch_reset();
/// Call after ui_begin() (epdiy must have created the bus).
void periph_begin();
void periph_tick(uint32_t now);
/// One finger: true while down, raw controller coordinates.
bool periph_touch(int* x, int* y);
/// True once when the capacitive circle/home key is pressed.
bool periph_home_key();
/// Controller's reported range (for mapping to the panel); 0 if unknown.
void periph_touch_range(int* max_x, int* max_y);
const char* periph_touch_kind();   // "gt911", "gt6972p", "none"
int  periph_batt_pct();            // -1 when no gauge
bool periph_gps_fix();
int  periph_gps_sats();

