// LilyGO T-Embed CC1101 (Plus) pin map — ESP32-S3R8, 1.9" ST7789 170x320,
// rotary encoder, 8x WS2812 ring, CC1101 sub-GHz radio, BQ27220 gauge.
// Pin facts from LilyGO's examples/utilities.h (T_EMBED_CC1101_HD_VER
// v1.0-240729).
#pragma once

#define PIN_PWR_EN     15   // peripheral rail: CC1101 + LED ring
#define PIN_USER_KEY   6    // side button, active low
#define PIN_ENC_A      4
#define PIN_ENC_B      5
#define PIN_ENC_KEY    0    // encoder push, active low (BOOT strap)
#define PIN_LED_DATA   14
#define LED_COUNT      8

#define PIN_LCD_BL     21
#define PIN_LCD_CS     41
#define PIN_LCD_DC     16
#define PIN_LCD_RST    40   // T-Embed CC1101 wires the panel reset (unlike the
                            // PN532 variant); driving it makes a cold-boot
                            // panel init reliable
#define PIN_SPI_SCK    11
#define PIN_SPI_MOSI   9
#define PIN_SPI_MISO   10

#define PIN_I2C_SDA    8
#define PIN_I2C_SCL    18
#define BQ27220_ADDR   0x55

#define PIN_CC_CS      12
#define PIN_CC_GDO0    3
#define PIN_CC_GDO2    38
#define PIN_CC_SW0     48   // RF path switch (see cc1101_sweep.cpp)
#define PIN_CC_SW1     47
#define PIN_SD_CS      13   // held high: shares the bus, never selected
