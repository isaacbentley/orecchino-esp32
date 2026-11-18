// LilyGO T5 E-Paper S3 Pro (4.7" ED047TC1 960x540, ESP32-S3R8, SX1262 LoRa,
// GT6972P touch, PCF8563 RTC, BQ27220 gauge). Pin facts from LilyGO's
// T5S3-4.7-e-paper-PRO examples/*/main/utilities.h. The panel itself is
// driven by epdiy's board_v7 definition (the PRO is a v7 layout).
#pragma once

#define PIN_I2C_SDA   39
#define PIN_I2C_SCL   40
#define BQ27220_ADDR  0x55
#define PIN_BOOT_BTN  0     // the only hardware button, active low
#define PIN_TOUCH_INT 3
#define TOUCH_RST_PIN 9
#define PIN_GPS_RX    44
#define PIN_GPS_TX    43
#define PIN_BL_EN     11    // Backlight boost enable / PWM (PT4103B23F)

#define PIN_SPI_MISO  21
#define PIN_SPI_MOSI  13
#define PIN_SPI_SCLK  14
#define PIN_LORA_CS   46
#define PIN_LORA_IRQ  10
#define PIN_LORA_RST  1
#define PIN_LORA_BUSY 47
#define PIN_SD_CS     12    // held high: shares the bus, never selected
