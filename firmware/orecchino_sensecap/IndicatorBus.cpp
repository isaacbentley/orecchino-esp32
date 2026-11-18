#include "IndicatorBus.h"
#include <Wire.h>

PCA9555 ind_ioex;
static bool s_exp_ready = false;

void indicator_expander_init() {
  if (s_exp_ready) return;
  Wire.begin(IND_I2C_SDA, IND_I2C_SCL, 400000);
  ind_ioex.attach(Wire);
  ind_ioex.polarity(PCA95x5::Polarity::ORIGINAL_ALL);

  ind_ioex.write(IND_EXP_LCD_RST, PCA95x5::Level::L);
  ind_ioex.direction(IND_EXP_LCD_RST, PCA95x5::Direction::OUT);
  ind_ioex.write(IND_EXP_TP_RST, PCA95x5::Level::L);
  ind_ioex.direction(IND_EXP_TP_RST, PCA95x5::Direction::OUT);

  ind_ioex.write(IND_EXP_RP2040_RST, PCA95x5::Level::H);
  ind_ioex.direction(IND_EXP_RP2040_RST, PCA95x5::Direction::OUT);

  // Deselect the SX1262 — it shares SCK/MOSI with the LCD init bus.
  ind_ioex.write(IND_EXP_RADIO_NSS, PCA95x5::Level::H);
  ind_ioex.direction(IND_EXP_RADIO_NSS, PCA95x5::Direction::OUT);

  delay(5);
  ind_ioex.write(IND_EXP_LCD_RST, PCA95x5::Level::H);
  ind_ioex.write(IND_EXP_TP_RST, PCA95x5::Level::H);
  delay(5);
  s_exp_ready = true;
}

bool IndicatorSWSPI::begin(int32_t, int8_t) {
  indicator_expander_init();
  pinMode(IND_SPI_SCK, OUTPUT);
  digitalWrite(IND_SPI_SCK, LOW);
  pinMode(IND_SPI_MOSI, OUTPUT);
  digitalWrite(IND_SPI_MOSI, LOW);
  ind_ioex.write(IND_EXP_LCD_CS, PCA95x5::Level::H);
  ind_ioex.direction(IND_EXP_LCD_CS, PCA95x5::Direction::OUT);
  return true;
}

// 9-bit frame: D/C bit first, then the data byte MSB-first.
void IndicatorSWSPI::w9(bool dc, uint8_t b) {
  uint16_t v = (dc ? 0x100 : 0x000) | b;
  for (int i = 8; i >= 0; i--) {
    digitalWrite(IND_SPI_MOSI, (v >> i) & 1);
    digitalWrite(IND_SPI_SCK, HIGH);
    digitalWrite(IND_SPI_SCK, LOW);
  }
}

void IndicatorSWSPI::beginWrite() {
  ind_ioex.write(IND_EXP_LCD_CS, PCA95x5::Level::L);
}
void IndicatorSWSPI::endWrite() {
  ind_ioex.write(IND_EXP_LCD_CS, PCA95x5::Level::H);
}
void IndicatorSWSPI::writeCommand(uint8_t c) { w9(false, c); }
void IndicatorSWSPI::writeCommand16(uint16_t c) {
  w9(false, c >> 8);
  w9(false, c & 0xFF);
}
void IndicatorSWSPI::writeCommandBytes(uint8_t* data, uint32_t len) {
  while (len--) w9(false, *data++);
}
void IndicatorSWSPI::write(uint8_t d) { w9(true, d); }
void IndicatorSWSPI::write16(uint16_t d) {
  w9(true, d >> 8);
  w9(true, d & 0xFF);
}
void IndicatorSWSPI::writeRepeat(uint16_t p, uint32_t len) {
  while (len--) write16(p);
}
void IndicatorSWSPI::writePixels(uint16_t* data, uint32_t len) {
  while (len--) write16(*data++);
}
#if !defined(LITTLE_FOOT_PRINT)
void IndicatorSWSPI::writeBytes(uint8_t* data, uint32_t len) {
  while (len--) w9(true, *data++);
}
#endif
