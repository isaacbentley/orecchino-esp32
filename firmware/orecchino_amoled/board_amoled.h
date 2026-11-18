// Waveshare ESP32-C6-Touch-AMOLED-1.8 — ESP32-C6 (single RISC-V core, no
// PSRAM, 16 MB flash), 1.8" SH8601 AMOLED 368x448 over QSPI, FT3168 touch,
// AXP2101 PMU, TCA9554 expander gating display/touch power. Pin facts from
// Waveshare's examples/arduino/libraries/Mylibrary/pin_config.h.
#pragma once

#define LCD_W        368
#define LCD_H        448
// The glass is a rounded rectangle: nothing important may sit in the four
// corners. CORNER_R is the panel's corner radius (tune if a corner clips);
// SAFE_X is the horizontal inset for anything drawn within the corner band.
#define CORNER_R     44
#define SAFE_X       30
#define PIN_LCD_CS   5
#define PIN_LCD_SCK  0
#define PIN_LCD_D0   1
#define PIN_LCD_D1   2
#define PIN_LCD_D2   3
#define PIN_LCD_D3   4

#define PIN_I2C_SDA  8
#define PIN_I2C_SCL  7
#define PIN_TP_INT   15
#define FT3168_ADDR  0x38   // older rev; newer rev is CST816 at 0x15 (same regs)
#define AXP2101_ADDR 0x34
#define TCA9554_ADDR 0x20
#define IOX_LCD_PWR  4   // P4: display power, active high
#define IOX_TP_PWR   5   // P5: touch power, active high

#define PIN_BOOT_BTN 9   // the only hardware button, active low
