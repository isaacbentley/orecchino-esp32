#include "t5_periph.h"
#include "board_t5.h"
#include "driver/i2c_master.h"
#include "../common/ui_common.h"   // g_home_*

static i2c_master_bus_handle_t s_bus = nullptr;
static i2c_master_dev_handle_t s_pca = nullptr, s_tp = nullptr, s_gauge = nullptr;
static bool s_have_gauge = false;
enum TpKind : uint8_t { TP_NONE, TP_GT911, TP_GT6972P };
static TpKind s_tp_kind = TP_NONE;
static uint32_t s_tp_data_addr = 0;   // GT6972P: from its IC-info block
static int s_tp_max_x = 0, s_tp_max_y = 0;
static bool s_gps_fix = false;
static int  s_gps_sats = 0;
static uint32_t s_gps_fix_ms = 0;

// ---- bus helpers
static i2c_master_dev_handle_t dev_add(uint8_t addr) {
  i2c_device_config_t cfg = {};
  cfg.dev_addr_length = I2C_ADDR_BIT_LEN_7;
  cfg.device_address = addr;
  cfg.scl_speed_hz = 400000;
  i2c_master_dev_handle_t d = nullptr;
  if (i2c_master_bus_add_device(s_bus, &cfg, &d) != ESP_OK) return nullptr;
  return d;
}
static bool wr(i2c_master_dev_handle_t d, const uint8_t* w, size_t wl) {
  return d && i2c_master_transmit(d, w, wl, 50) == ESP_OK;
}
static bool wrrd(i2c_master_dev_handle_t d, const uint8_t* w, size_t wl, uint8_t* r, size_t rl) {
  return d && i2c_master_transmit_receive(d, w, wl, r, rl, 50) == ESP_OK;
}
static bool present(uint8_t addr) { return i2c_master_probe(s_bus, addr, 30) == ESP_OK; }

// ---- PCA9555: read-modify-write on port 0 only; port 1 belongs to epdiy
static bool pca_rmw(uint8_t reg, uint8_t clear, uint8_t set) {
  uint8_t v = 0;
  if (!wrrd(s_pca, &reg, 1, &v, 1)) return false;
  v = (v & ~clear) | set;
  uint8_t w[2] = { reg, v };
  return wr(s_pca, w, 2);
}
static void rail_on() {
  s_pca = dev_add(0x20);
  if (!s_pca) return;
  pca_rmw(0x06, 0x01, 0x00);   // config port 0: bit 0 output
  pca_rmw(0x02, 0x00, 0x01);   // output port 0: LORA_EN high -> LoRa + GPS 3V3
  delay(100);
}

// ---- Goodix GT911 (16-bit registers, big-endian)
static bool s_home_key = false;
bool periph_home_key() {
  if (s_home_key) {
    s_home_key = false;
    return true;
  }
  return false;
}

void periph_touch_reset() {
  pinMode(TOUCH_RST_PIN, OUTPUT);
  pinMode(PIN_TOUCH_INT, OUTPUT);
  digitalWrite(PIN_TOUCH_INT, LOW);  // INT low -> GT911 latches address 0x5D
  digitalWrite(TOUCH_RST_PIN, LOW);  // assert RST
  delay(15);
  digitalWrite(TOUCH_RST_PIN, HIGH); // release RST while INT is still LOW
  delay(10);
  pinMode(PIN_TOUCH_INT, INPUT);     // release INT to high-Z (GT911 drives it now)
  pinMode(TOUCH_RST_PIN, INPUT);     // high-Z so epdiy can claim GPIO9 for LCD D8
  delay(60);                         // wait out GT911 firmware boot
}

static bool gt911_rd(uint16_t reg, uint8_t* r, size_t n) {
  uint8_t a[2] = { (uint8_t)(reg >> 8), (uint8_t)reg };
  return wrrd(s_tp, a, 2, r, n);
}
static bool gt911_wr8(uint16_t reg, uint8_t v) {
  uint8_t w[3] = { (uint8_t)(reg >> 8), (uint8_t)reg, v };
  return wr(s_tp, w, 3);
}
static bool gt911_probe() {
  uint8_t id[5] = {0};
  if (!gt911_rd(0x8140, id, 4)) return false;
  if (memcmp(id, "911", 3) != 0 && memcmp(id, "927", 3) != 0 && memcmp(id, "928", 3) != 0) return false;
  uint8_t r[4] = {0};
  if (gt911_rd(0x8048, r, 4)) {
    int rx = r[0] | (r[1] << 8);
    int ry = r[2] | (r[3] << 8);
    if (rx > 0 && ry > 0) {
      s_tp_max_x = rx;
      s_tp_max_y = ry;
    }
  }
  if (s_tp_max_x <= 0 || s_tp_max_y <= 0) {
    s_tp_max_x = 540;
    s_tp_max_y = 960;
  }
  return true;
}
static int gt911_read_point(int* x, int* y) {
  uint8_t st = 0;
  if (!gt911_rd(0x814E, &st, 1)) return 0;
  if (!(st & 0x80)) return 0;

  // The round capacitive home button below the screen sets bit 4 (HaveKey)
  if (st & 0x10) {
    static uint32_t s_last_home = 0;
    uint32_t now = millis();
    if (now - s_last_home >= 500) {
      s_last_home = now;
      s_home_key = true;
      Serial.println("{\"type\":\"home_button\"}");
    }
  }

  int n = st & 0x0F;
  int res = 0;
  if (n > 0) {
    uint8_t p[8];
    if (gt911_rd(0x814F, p, 8)) {
      *x = p[1] | (p[2] << 8);
      *y = p[3] | (p[4] << 8);
      res = 1;
    }
  } else {
    res = -1; // 0 points reported = explicit finger release
  }
  gt911_wr8(0x814E, 0);
  return res;
}

// ---- Goodix GT6972P ("Berlin": 32-bit registers, big-endian, 64 B chunks)
static bool gt6_rd(uint32_t reg, uint8_t* r, size_t n) {
  for (size_t pos = 0; pos < n; pos += 64) {
    uint32_t a = reg + pos;
    uint8_t ab[4] = { (uint8_t)(a >> 24), (uint8_t)(a >> 16), (uint8_t)(a >> 8), (uint8_t)a };
    size_t chunk = n - pos < 64 ? n - pos : 64;
    if (!wrrd(s_tp, ab, 4, r + pos, chunk)) return false;
  }
  return true;
}
static bool gt6_wr(uint32_t reg, const uint8_t* d, size_t n) {
  uint8_t buf[4 + 64];
  buf[0] = reg >> 24; buf[1] = reg >> 16; buf[2] = reg >> 8; buf[3] = reg;
  memcpy(buf + 4, d, n);
  return wr(s_tp, buf, 4 + n);
}
static uint16_t le16(const uint8_t* p) { return p[0] | (p[1] << 8); }
static uint32_t le32(const uint8_t* p) { return le16(p) | ((uint32_t)le16(p + 2) << 16); }
static bool sum_ok(const uint8_t* d, size_t n) {   // 16-bit sum, LE trailer
  uint32_t s = 0;
  for (size_t i = 0; i + 2 < n + 0 && i < n - 2; i++) s += d[i];
  return (uint16_t)s == le16(d + n - 2);
}
static bool gt6_probe() {
  static const uint8_t pat[8] = { 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA };
  uint8_t back[8] = {0};
  if (!gt6_wr(0x10000, pat, 8) || !gt6_rd(0x10000, back, 8) || memcmp(pat, back, 8) != 0) return false;
  // IC info block (version 2 layout): length-prefixed, checksummed. Walk the
  // packages to the address package, where the touch-data address lives.
  uint8_t hdr[4], info[256];
  if (!gt6_rd(0x10070, hdr, 4)) return false;
  size_t len = le16(hdr);
  if (len < 8 || len >= sizeof(info) || !gt6_rd(0x10070, info, len) || !sum_ok(info, len)) return false;
  if (info[3] != 0x02) return false;
  size_t off = 2 + 10 + 16 + 8 + 4;             // head, version, bsp, param header
  for (int i = 0; i < 5; i++) {                 // five frequency lists: count + 2 B each
    if (off >= len - 2) return false;
    uint8_t c = info[off++];
    if (c > 8) return false;
    off += (size_t)c * 2;
  }
  if (off + 28 + 24 > len - 2) return false;
  off += 28;
  s_tp_data_addr = le32(info + off + 11);
  s_tp_max_x = le16(info + off + 19);
  s_tp_max_y = le16(info + off + 21);
  return s_tp_data_addr != 0;
}
static bool gt6_read(int* x, int* y) {
  uint8_t b[16];
  if (!gt6_rd(s_tp_data_addr, b, 16)) return false;
  if (b[0] == 0) return false;
  bool down = false;
  if ((b[0] & 0x80) && sum_ok(b, 8)) {
    int n = b[2] & 0x0F;
    uint8_t type = b[8] & 0x0F;
    if (n > 0 && (type == 2 || type == 4)) { *x = le16(b + 10); *y = le16(b + 12); down = true; }
  }
  uint8_t zero = 0;
  gt6_wr(s_tp_data_addr, &zero, 1);
  return down;
}

static void touch_begin() {
  if (!present(0x5D) && !present(0x14)) {
    periph_touch_reset();
  }
  for (uint8_t addr : { (uint8_t)0x5D, (uint8_t)0x14 }) {
    if (!present(addr)) continue;
    s_tp = dev_add(addr);
    if (!s_tp) continue;
    if (gt911_probe()) { s_tp_kind = TP_GT911; return; }
    if (gt6_probe())   { s_tp_kind = TP_GT6972P; return; }
    i2c_master_bus_rm_device(s_tp);
    s_tp = nullptr;
  }
}

bool periph_touch(int* x, int* y) {
  if (s_tp_kind == TP_NONE) return false;
  static bool down = false;
  static int lx = 0, ly = 0;
  static uint32_t last_touch_ms = 0;
  uint32_t now = millis();

  if (s_tp_kind == TP_GT911) {
    int tx = 0, ty = 0;
    int res = gt911_read_point(&tx, &ty);
    if (res == 1) {
      lx = tx; ly = ty;
      down = true;
      last_touch_ms = now;
      *x = tx; *y = ty;
      return true;
    } else if (res == -1) {
      down = false;
      return false;
    } else {
      if (down && now - last_touch_ms > 60) down = false;
      if (down) { *x = lx; *y = ly; return true; }
      return false;
    }
  } else {
    int tx = 0, ty = 0;
    bool d = gt6_read(&tx, &ty);
    if (d) { lx = tx; ly = ty; down = true; last_touch_ms = now; *x = tx; *y = ty; return true; }
    if (down && now - last_touch_ms > 60) down = false;
    if (down) { *x = lx; *y = ly; return true; }
    return false;
  }
}
void periph_touch_range(int* mx, int* my) { *mx = s_tp_max_x; *my = s_tp_max_y; }
const char* periph_touch_kind() { return s_tp_kind == TP_GT911 ? "gt911" : s_tp_kind == TP_GT6972P ? "gt6972p" : "none"; }

// ---- BQ27220
int periph_batt_pct() {
  if (!s_have_gauge) return -1;
  uint8_t reg = 0x2C, r[2] = {0};   // StateOfCharge, percent
  if (!wrrd(s_gauge, &reg, 1, r, 2)) return -1;
  int pct = r[0] | (r[1] << 8);
  return pct > 100 ? 100 : pct;
}

// ---- GPS: NMEA over UART1, baud found by listening
static const uint32_t GPS_BAUDS[] = { 9600, 38400, 115200 };
static int s_gps_baud_i = 0;
static uint32_t s_gps_last_sentence = 0, s_gps_baud_since = 0;
static char s_nmea[120];
static int s_nmea_n = 0;

static double nmea_coord(const char* f, const char* hemi) {
  if (!f[0]) return NAN;
  double v = atof(f);
  int deg = (int)(v / 100);
  double m = v - deg * 100;
  double d = deg + m / 60.0;
  if (hemi[0] == 'S' || hemi[0] == 'W') d = -d;
  return d;
}
static void nmea_line(const char* s, uint32_t now) {
  s_gps_last_sentence = now;
  if (strlen(s) < 6 || s[0] != '$') return;
  if (strncmp(s + 3, "GGA", 3) != 0) return;
  char f[15][16] = {{0}};
  int fi = 0, fc = 0;
  for (const char* p = s; *p && fi < 15; p++) {
    if (*p == ',' || *p == '*') { f[fi][fc] = 0; fi++; fc = 0; if (*p == '*') break; }
    else if (fc < 15) f[fi][fc++] = *p;
  }
  int quality = atoi(f[6]);
  s_gps_sats = atoi(f[7]);
  if (quality > 0) {
    double lat = nmea_coord(f[2], f[3]), lon = nmea_coord(f[4], f[5]);
    if (!isnan(lat) && !isnan(lon) && (lat != 0 || lon != 0)) {
      g_home_lat = lat; g_home_lon = lon; g_home_set = true;
      s_gps_fix = true; s_gps_fix_ms = now;
    }
  }
}
bool periph_gps_fix() { return s_gps_fix; }
int  periph_gps_sats() { return s_gps_sats; }

void periph_begin() {
  if (i2c_master_get_bus_handle(0, &s_bus) != ESP_OK || !s_bus) return;
  rail_on();
  touch_begin();
  if (present(BQ27220_ADDR)) { s_gauge = dev_add(BQ27220_ADDR); s_have_gauge = s_gauge != nullptr; }
  Serial1.begin(GPS_BAUDS[0], SERIAL_8N1, PIN_GPS_RX, PIN_GPS_TX);
  s_gps_baud_since = millis();
  Serial.printf("{\"type\":\"periph\",\"touch\":\"%s\",\"touch_range\":[%d,%d],\"gauge\":%s,\"rail\":%s}\n",
                periph_touch_kind(), s_tp_max_x, s_tp_max_y, s_have_gauge ? "true" : "false",
                s_pca ? "true" : "false");
}

void periph_tick(uint32_t now) {
  while (Serial1.available()) {
    char c = (char)Serial1.read();
    if (c == '\n' || c == '\r') {
      if (s_nmea_n > 0) { s_nmea[s_nmea_n] = 0; nmea_line(s_nmea, now); s_nmea_n = 0; }
    } else if (s_nmea_n < (int)sizeof(s_nmea) - 1) s_nmea[s_nmea_n++] = c;
    else s_nmea_n = 0;
  }
  // No sentence for 4 s on this baud: try the next one.
  if (now - s_gps_last_sentence > 4000 && now - s_gps_baud_since > 4000) {
    s_gps_baud_i = (s_gps_baud_i + 1) % 3;
    Serial1.updateBaudRate(GPS_BAUDS[s_gps_baud_i]);
    s_gps_baud_since = now;
  }
  if (s_gps_fix && now - s_gps_fix_ms > 30000) s_gps_fix = false;
  static uint32_t last_rep = 0;
  if (s_gps_fix && now - last_rep >= 10000) {
    last_rep = now;
    Serial.printf("{\"type\":\"gps\",\"fix\":true,\"sats\":%d,\"lat\":%.6f,\"lon\":%.6f}\n",
                  s_gps_sats, g_home_lat, g_home_lon);
  }
}
