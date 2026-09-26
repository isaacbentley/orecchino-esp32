// T5 E-Paper S3 Pro peripherals that live on the I2C bus epdiy owns —
// reached through the ESP-IDF i2c_master bus handle epdiy created, never
// through the Arduino two-wire library (the port cannot carry both drivers).
//
//   * PCA9555 IO expander: epdiy drives its port 1 for the panel; port 0
//     bit 0 is LORA_EN, the 3V3 rail feeding the SX1262 *and* the GPS.
//   * Touch: a Goodix controller — GT911 on some batches, the GT6972P
//     ("Berlin" register map) on others. Probed at boot; one finger is all
//     a slow panel needs (tap and drag-release).
//   * BQ27220 fuel gauge: state of charge, cell voltage and current. At
//     boot it is checked against the 1500 mAh cell's profile and rewritten
//     when it holds anything else (firmware/common/bq27220.h).
//   * GPS on UART1 (RX 44 / TX 43): NMEA GGA and RMC (t5_nmea.h) parsed
//     into the operator position and the clock, so the board self-locates
//     in the field without the app; a sentence without a fix sets neither.
#pragma once
#include <Arduino.h>
#include <time.h>

/// Optional pre-init: pulses GT911 RST/INT to latch address 0x5D before epdiy claims GPIO9
void periph_touch_reset();
/// Call after ui_begin() (epdiy must have created the bus).
void periph_begin();
void periph_tick(uint32_t now);
enum TouchEventType : uint8_t {
  TOUCH_EVT_NONE = 0,
  TOUCH_EVT_TAP,
  TOUCH_EVT_DRAG
};

struct TouchEvent {
  TouchEventType type;
  int16_t x;
  int16_t y;
  int16_t dx;
  int16_t dy;
  uint32_t ms;
};

/// Fetch next queued touch event produced asynchronously on Core 0. Returns false if empty.
bool periph_poll_touch_event(TouchEvent* evt);

/// One finger: true while down, raw controller coordinates.
bool periph_touch(int* x, int* y);
/// True once when the capacitive circle/home key is pressed.
bool periph_home_key();
/// Controller's reported range (for mapping to the panel); 0 if unknown.
void periph_touch_range(int* max_x, int* max_y);
int  periph_batt_pct();            // -1 when no gauge
int  periph_batt_mv();             // -1 when no gauge (cell mV from BQ27220)
/// The capacity the percentage is counted against (FullChargeCapacity()), -1 when no gauge.
int  periph_batt_full_mah();
/// True when the gauge holds this board's cell profile.
bool periph_gauge_configured();
/// The gauge's whole state as one JSON line (the host's `gauge` command);
/// false when there is no gauge.
bool periph_gauge_json(char* out, size_t n);
bool periph_gps_detected();        // true when valid NMEA sentences received on UART1
bool periph_gps_fix();
int  periph_gps_sats();
/// Height above the WGS-84 ellipsoid from the last GGA fix, NAN without a fix.
float periph_gps_elev_m();

enum BlMode : uint8_t { BL_AUTO = 0, BL_ON = 1, BL_OFF = 2 };

void    periph_bl_init();
void    periph_bl_set_mode(BlMode mode);
BlMode  periph_bl_get_mode();
void    periph_bl_set_duty(uint8_t duty);
uint8_t periph_bl_get_duty();
bool    periph_bl_is_active();
/// Flash the front light `times` times at full brightness (a new traffic
/// warning), whatever the mode and the time of day; nothing is saved.
void    periph_bl_pulse(uint8_t times);
bool    periph_is_after_sundown();
double  periph_sun_elevation();
bool    periph_has_utc_time();
void    periph_get_utc_time(uint16_t* y, uint8_t* m, uint8_t* d, uint8_t* h, uint8_t* min, uint8_t* s);
void    periph_set_utc_time(uint16_t y, uint8_t m, uint8_t d, uint8_t h, uint8_t min, uint8_t s);
/// Set the clock from a host (the flash script, the Mac app). Unlike the
/// GPS path, which writes the RTC chip at most hourly, this always writes
/// the chip, so the time survives the next reset. False when the date is
/// out of range.
bool    periph_set_utc_time_host(time_t epoch);
/// The RTC chip's own time, "YYYY-MM-DDTHH:MM:SSZ". False when there is no
/// chip, it does not answer, or it flags its time as lost.
bool    periph_rtc_iso(char* out, size_t n);

// Power management and the IO48 key. The key silk-screened IO48 is LilyGO's
// function button S3 on PCA9535 IO1_2 (GPIO48 itself drives the panel's CKV).
// PWR is not wired to the MCU at all: it only switches the board on.
bool    periph_is_charging();
bool    periph_on_vbus();
bool    periph_io48_key_down();
void    periph_power_off();

