// Minimal write-only 9-bit SPI bus for the SenseCAP Indicator's ST7701S
// init, with chip-select and resets routed through the TCA9535 IO expander.
//
// Interface modeled on Arduino_SWSPI from Arduino_GFX (BSD license,
// moononournation/Arduino_GFX); pin wiring per Seeed's Apache-2.0 BSP
// (SenseCAP_Indicator_ESP32, sensecap_indicator_board.c). Only the paths the
// panel init sequence exercises are implemented — this bus is idle after
// boot, all pixel traffic rides the 16-bit RGB interface.
#pragma once
#include <Arduino_GFX_Library.h>
#include <PCA95x5.h>

#define IND_I2C_SDA   39
#define IND_I2C_SCL   40
#define IND_SPI_SCK   41
#define IND_SPI_MOSI  48

#define IND_EXP_RADIO_NSS  PCA95x5::Port::P00
#define IND_EXP_LCD_CS     PCA95x5::Port::P04
#define IND_EXP_LCD_RST    PCA95x5::Port::P05
#define IND_EXP_TP_RST     PCA95x5::Port::P07
#define IND_EXP_RP2040_RST PCA95x5::Port::P10  // second bank bit 0 (IO1_0)

extern PCA9555 ind_ioex;

/// Bring up Wire + the expander: LCD/touch out of reset, RP2040 held
/// running, LoRa radio deselected off the shared SPI bus. Idempotent.
void indicator_expander_init();

class IndicatorSWSPI : public Arduino_DataBus {
 public:
  IndicatorSWSPI() {}

  bool begin(int32_t speed = GFX_NOT_DEFINED,
             int8_t dataMode = GFX_NOT_DEFINED) override;
  void beginWrite() override;
  void endWrite() override;
  void writeCommand(uint8_t c) override;
  void writeCommand16(uint16_t c) override;
  void writeCommandBytes(uint8_t* data, uint32_t len) override;
  void write(uint8_t d) override;
  void write16(uint16_t d) override;
  void writeRepeat(uint16_t p, uint32_t len) override;
  void writePixels(uint16_t* data, uint32_t len) override;
#if !defined(LITTLE_FOOT_PRINT)
  void writeBytes(uint8_t* data, uint32_t len) override;
#endif

 private:
  void w9(bool dc, uint8_t b);
};
