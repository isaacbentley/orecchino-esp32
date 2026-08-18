// Host-side unit tests for the shared ASTM F3411 decoder.
//
// The golden vector is the first beacon of odid_wifi_bcn_sample.pcap from
// opendroneid/wireshark-dissector (Apache-2.0); every expected value below
// was cross-checked against that project's reference Wireshark dissector.
//
// Build + run:  cc -std=c11 -Wall -Wextra -O2 tests/odid_test.c -o /tmp/odid_test && /tmp/odid_test
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#include "../firmware/common/odid_build.h"
#include "../firmware/common/odid_decode.h"

static int g_fail = 0, g_pass = 0;

#define CHECK(cond, name)                                    \
  do {                                                       \
    if (cond) {                                              \
      g_pass++;                                              \
    } else {                                                 \
      g_fail++;                                              \
      printf("FAIL %s (%s:%d)\n", name, __FILE__, __LINE__); \
    }                                                        \
  } while (0)

#define CHECK_F(a, b, eps, name) CHECK(fabs((a) - (b)) < (eps), name)
#define CHECK_S(a, b, name) CHECK(strcmp((a), (b)) == 0, name)

static int hex2bin(const char* hex, uint8_t* out, int max) {
  int n = 0;
  while (hex[0] && hex[1] && n < max) {
    unsigned b;
    if (sscanf(hex, "%2x", &b) != 1) break;
    out[n++] = (uint8_t)b;
    hex += 2;
  }
  return n;
}

// odid_wifi_bcn_sample.pcap frame 1, vendor IE payload after the message
// counter: a 5-message pack (Basic ID, Location, Self ID, System, Operator).
static const char* GOLDEN_PACK =
    "f0190500004d4647314130313233343536373839000000000000"
    "50f610005c527ebcba251ba88cb4b60000aa099808394100000a"
    "00300052656372656174696f6e616c000000000000000000000"
    "04004a485251b6edbb3b601003200000000150000000000000050"
    "004742522d4f502d31323341424344000000000000000000";

static void test_golden_pack(void) {
  uint8_t buf[256];
  int n = hex2bin(GOLDEN_PACK, buf, sizeof(buf));
  CHECK(n == 128, "golden: payload length");

  OdidUas u;
  CHECK(odid_decode_payload(buf, n, &u), "golden: pack decodes");

  // Basic ID (dissector: ID Type None, UA Type None, ID MFG1A0123456789)
  CHECK(u.has_basic[0], "golden: basic present");
  CHECK(u.id_type[0] == 0, "golden: id_type");
  CHECK(u.ua_type[0] == 0, "golden: ua_type");
  CHECK_S(u.uas_id[0], "MFG1A0123456789", "golden: uas id");

  // Location (dir 92, speed 20.50 m/s, vspeed Unknown(126), lat 45.5457468,
  // lon -122.9681496, baro Unknown, geo 237.0 m, height 100.0 m, H<30m(9),
  // V<25m(3), Baro<10m(4), Speed<10m/s(1), ts 0, ts_acc 10)
  CHECK(u.has_loc, "golden: loc present");
  CHECK(u.status == 0, "golden: status");
  CHECK(u.height_ref == 0, "golden: height ref");
  CHECK_F(u.dir, 92.0f, 0.01, "golden: direction");
  CHECK_F(u.speed, 20.50f, 0.001, "golden: speed");
  CHECK_F(u.vspeed, -999.0f, 0.001, "golden: vspeed unknown marker");
  CHECK_F(u.lat, 45.5457468, 5e-7, "golden: latitude");
  CHECK_F(u.lon, -122.9681496, 5e-7, "golden: longitude");
  CHECK_F(u.alt_baro, -1000.0f, 0.001, "golden: baro alt unknown");
  CHECK_F(u.alt_geo, 237.0f, 0.001, "golden: geo alt");
  CHECK_F(u.height, 100.0f, 0.001, "golden: height");
  CHECK(u.h_acc == 9, "golden: h_acc");
  CHECK(u.v_acc == 3, "golden: v_acc");
  CHECK(u.baro_acc == 4, "golden: baro_acc");
  CHECK(u.spd_acc == 1, "golden: spd_acc");
  CHECK_F(u.ts, 0.0f, 0.001, "golden: timestamp");
  CHECK(u.ts_acc == 10, "golden: ts_acc");

  // Self ID
  CHECK(u.has_self, "golden: self present");
  CHECK(u.self_type == 0, "golden: self type");
  CHECK_S(u.self_desc, "Recreational", "golden: self desc");

  // System (EU classification, take-off op location, op lat 45.5443876,
  // op lon -122.9726866, area count 1 radius 500 m, Open(1)/Class 4(5))
  CHECK(u.has_sys, "golden: system present");
  CHECK(u.class_type == 1, "golden: classification type");
  CHECK(u.op_loc_type == 0, "golden: op location type");
  CHECK_F(u.op_lat, 45.5443876, 5e-7, "golden: op latitude");
  CHECK_F(u.op_lon, -122.9726866, 5e-7, "golden: op longitude");
  CHECK(u.area_count == 1, "golden: area count");
  CHECK_F(u.area_radius, 500.0f, 0.001, "golden: area radius");
  CHECK_F(u.area_ceiling, -1000.0f, 0.001, "golden: area ceiling unknown");
  CHECK_F(u.area_floor, -1000.0f, 0.001, "golden: area floor unknown");
  CHECK(u.cat_eu == 1, "golden: EU category");
  CHECK(u.class_eu == 5, "golden: EU class");
  CHECK_F(u.op_alt, -1000.0f, 0.001, "golden: op alt unknown");
  CHECK(u.sys_ts == 0, "golden: system timestamp");

  // Operator ID
  CHECK(u.has_op, "golden: operator present");
  CHECK(u.op_id_type == 0, "golden: op id type");
  CHECK_S(u.op_id, "GBR-OP-123ABCD", "golden: operator id");
}

static void loc_msg(uint8_t* m, uint8_t flags, uint8_t dir, uint8_t speed,
                    uint8_t vspd) {
  memset(m, 0, 25);
  m[0] = 0x12;  // Location, proto v2
  m[1] = flags;
  m[2] = dir;
  m[3] = speed;
  m[4] = vspd;
}

static void test_location_scales(void) {
  uint8_t m[25];
  OdidUas u;

  // Speed multiplier 1: 82 * 0.75 + 63.75 = 125.25 m/s
  loc_msg(m, 0x01, 10, 82, 0);
  CHECK(odid_decode_payload(m, 25, &u), "scale: mult decodes");
  CHECK_F(u.speed, 125.25f, 0.001, "scale: speed multiplier");

  // East/West bit: dir 92 + 180 = 272
  loc_msg(m, 0x02, 92, 0, 0);
  odid_decode_payload(m, 25, &u);
  CHECK_F(u.dir, 272.0f, 0.01, "scale: EW direction segment");

  // Direction raw > 180 is invalid
  loc_msg(m, 0x00, 200, 0, 0);
  odid_decode_payload(m, 25, &u);
  CHECK_F(u.dir, -1.0f, 0.001, "scale: invalid direction");

  // Speed 255 = unknown
  loc_msg(m, 0x00, 0, 255, 0);
  odid_decode_payload(m, 25, &u);
  CHECK_F(u.speed, -1.0f, 0.001, "scale: unknown speed");

  // Negative vertical speed: raw -20 = -10 m/s
  loc_msg(m, 0x00, 0, 0, (uint8_t)(int8_t)-20);
  odid_decode_payload(m, 25, &u);
  CHECK_F(u.vspeed, -10.0f, 0.001, "scale: negative vspeed");

  // Timestamp 0xFFFF = unknown
  loc_msg(m, 0x00, 0, 0, 0);
  m[21] = 0xFF;
  m[22] = 0xFF;
  odid_decode_payload(m, 25, &u);
  CHECK_F(u.ts, -1.0f, 0.001, "scale: unknown timestamp");

  // Height type flag = AGL
  loc_msg(m, 0x04, 0, 0, 0);
  odid_decode_payload(m, 25, &u);
  CHECK(u.height_ref == 1, "scale: height type AGL");
}

static void test_basic_id_utm_uuid(void) {
  uint8_t m[25];
  memset(m, 0, 25);
  m[0] = 0x02;        // Basic ID
  m[1] = 0x32;        // id_type 3 (UTM UUID), ua_type 2
  for (int i = 0; i < 20; i++) m[2 + i] = (uint8_t)(0xA0 + i);
  OdidUas u;
  CHECK(odid_decode_payload(m, 25, &u), "uuid: decodes");
  CHECK(u.id_type[0] == 3, "uuid: id type");
  CHECK(u.ua_type[0] == 2, "uuid: ua type");
  CHECK_S(u.uas_id[0], "a0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3",
          "uuid: hex encoding");
}

static void test_text_sanitization(void) {
  uint8_t m[25];
  memset(m, 0, 25);
  m[0] = 0x32;  // Self ID
  m[1] = 0;
  const uint8_t evil[] = "A\"B\\C\x1f\x80 end  ";
  memcpy(m + 2, evil, sizeof(evil) - 1);
  OdidUas u;
  odid_decode_payload(m, 25, &u);
  CHECK_S(u.self_desc, "A.B.C.. end", "sanitize: JSON-breaking chars + trim");
}

static void test_pack_bounds(void) {
  uint8_t d[256];
  OdidUas u;

  // Short buffer rejected
  memset(d, 0, sizeof(d));
  CHECK(!odid_decode_payload(d, 24, &u), "bounds: short buffer");

  // Pack with wrong message size rejected
  d[0] = 0xF2;
  d[1] = 24;
  d[2] = 1;
  CHECK(!odid_decode_payload(d, 30, &u), "bounds: bad pack msg size");

  // Truncated pack decodes only the complete messages
  memset(d, 0, sizeof(d));
  d[0] = 0xF2;
  d[1] = 25;
  d[2] = 2;                    // claims 2 messages...
  d[3] = 0x02;                 // Basic ID, serial
  d[4] = 0x12;
  memcpy(d + 5, "TRUNCATED-PACK", 14);
  CHECK(odid_decode_payload(d, 3 + 25, &u), "bounds: truncated pack decodes");
  CHECK(u.has_basic[0] && !u.has_loc, "bounds: only complete message");

  // Auth-only content yields no useful fields -> false
  memset(d, 0, sizeof(d));
  d[0] = 0x22;  // Auth message
  CHECK(!odid_decode_payload(d, 25, &u), "bounds: auth-only rejected");

  // Pack message-count clamp: claims 200, buffer has 1
  memset(d, 0, sizeof(d));
  d[0] = 0xF2;
  d[1] = 25;
  d[2] = 200;
  d[3] = 0x02;
  d[4] = 0x12;
  d[5] = 'X';
  CHECK(odid_decode_payload(d, 3 + 25, &u), "bounds: count clamp decodes");
  CHECK_S(u.uas_id[0], "X", "bounds: clamped pack content");
}

static void test_dual_basic_id(void) {
  uint8_t d[3 + 50];
  memset(d, 0, sizeof(d));
  d[0] = 0xF2;
  d[1] = 25;
  d[2] = 2;
  d[3] = 0x02;                       // serial
  d[4] = 0x12;
  memcpy(d + 5, "SERIAL-1", 8);
  d[28] = 0x02;                      // CAA registration
  d[29] = 0x22;
  memcpy(d + 30, "CAA-REG-1", 9);
  OdidUas u;
  CHECK(odid_decode_payload(d, sizeof(d), &u), "dual: decodes");
  CHECK(u.has_basic[0] && u.has_basic[1], "dual: both slots");
  CHECK_S(u.uas_id[0], "SERIAL-1", "dual: slot 0");
  CHECK_S(u.uas_id[1], "CAA-REG-1", "dual: slot 1");
  CHECK(u.id_type[1] == 2, "dual: slot 1 type");
}

// The encoder (used by the TX test beacon) must produce exactly what the
// decoder — itself pinned to the reference Wireshark dissector — reads back.
static void test_tx_roundtrip(void) {
  OdidTxState s;
  memset(&s, 0, sizeof(s));
  s.uas_id = "ORECCHINO-TEST-0001";
  s.proto_ver = 2;
  s.ua_type = 2;
  s.status = 2;
  s.lat = 37.803900;
  s.lon = -122.464000;
  s.alt_geo_m = 100.0f;
  s.height_m = 60.0f;
  s.speed_ms = 8.25f;
  s.vspeed_ms = 1.5f;
  s.dir_deg = 275.0f;
  s.ts_s = 1234.5f;
  s.self_desc = "orecchino TX self-test";
  s.op_lat = 37.803000;
  s.op_lon = -122.465000;
  s.op_alt_m = 15.0f;
  s.op_id = "TEST-OP-0001";

  uint8_t pack[256];
  int n = odid_build_pack(pack, &s, 238000000u);
  CHECK(n == 128, "tx: pack length");

  OdidUas u;
  CHECK(odid_decode_payload(pack, n, &u), "tx: decodes");
  CHECK_S(u.uas_id[0], "ORECCHINO-TEST-0001", "tx: uas id");
  CHECK(u.id_type[0] == 1, "tx: id type serial");
  CHECK(u.ua_type[0] == 2, "tx: ua type");
  CHECK(u.status == 2, "tx: status airborne");
  CHECK_F(u.lat, 37.803900, 5e-7, "tx: latitude");
  CHECK_F(u.lon, -122.464000, 5e-7, "tx: longitude");
  CHECK_F(u.alt_geo, 100.0f, 0.5, "tx: geo altitude");
  CHECK_F(u.height, 60.0f, 0.5, "tx: height");
  CHECK_F(u.speed, 8.25f, 0.25, "tx: speed");
  CHECK_F(u.vspeed, 1.5f, 0.5, "tx: vertical speed");
  CHECK_F(u.dir, 275.0f, 1.0, "tx: direction (E/W segment)");
  CHECK_F(u.ts, 1234.5f, 0.1, "tx: timestamp");
  CHECK_S(u.self_desc, "orecchino TX self-test", "tx: self description");
  CHECK_F(u.op_lat, 37.803000, 5e-7, "tx: operator latitude");
  CHECK_F(u.op_lon, -122.465000, 5e-7, "tx: operator longitude");
  CHECK_F(u.op_alt, 15.0f, 0.5, "tx: operator altitude");
  CHECK_S(u.op_id, "TEST-OP-0001", "tx: operator id");
  CHECK(u.sys_ts == 238000000u, "tx: system timestamp");

  // Unknown vertical speed must ride as the 126 marker and read back unknown.
  s.vspeed_ms = NAN;
  odid_build_pack(pack, &s, 0);
  CHECK(odid_decode_payload(pack, n, &u), "tx: decodes with unknown vspeed");
  CHECK_F(u.vspeed, -999.0f, 0.001, "tx: unknown vspeed marker survives");

  // Fast flight crosses into the 0.75 m/s multiplier band.
  s.vspeed_ms = 0.0f;
  s.speed_ms = 90.0f;
  s.dir_deg = 45.0f;
  odid_build_pack(pack, &s, 0);
  odid_decode_payload(pack, n, &u);
  CHECK_F(u.speed, 90.0f, 0.75, "tx: high-speed multiplier band");
  CHECK_F(u.dir, 45.0f, 1.0, "tx: east direction segment");
}

// Authentication pagination: page 0 carries LastPageIndex (not a count),
// the TOTAL length, a timestamp and 17 data bytes; later pages carry 23.
// Layout per opendroneid-core-c's opendroneid.h.
static void test_auth_pages(void) {
  OdidTxState s;
  memset(&s, 0, sizeof(s));
  s.proto_ver = 2;

  uint8_t data[64];
  for (int i = 0; i < 64; i++) data[i] = (uint8_t)i;

  CHECK(odid_auth_pages(17) == 1, "auth: 17 bytes is one page");
  CHECK(odid_auth_pages(18) == 2, "auth: 18 bytes spills to two");
  CHECK(odid_auth_pages(63) == 3, "auth: 63 bytes fills three pages");
  CHECK(odid_auth_pages(64) == 4, "auth: 64 bytes spills to four");
  CHECK(odid_auth_pages(17 + 15 * 23) == 16, "auth: 16 pages max");

  uint8_t m[25];
  odid_build_auth_page(m, &s, 1, 0, data, 64, 0x11223344);
  CHECK((m[0] >> 4) == 2, "auth: message type 2");
  CHECK((m[0] & 0x0F) == 2, "auth: protocol version");
  CHECK((m[1] >> 4) == 1, "auth: auth type in the high nibble");
  CHECK((m[1] & 0x0F) == 0, "auth: page number in the low nibble");
  CHECK(m[2] == 3, "auth: page 0 carries LastPageIndex, not a count");
  CHECK(m[3] == 64, "auth: page 0 carries the total length");
  CHECK(odid_rd_u32(m + 4) == 0x11223344, "auth: page 0 timestamp");
  CHECK(memcmp(m + 8, data, 17) == 0, "auth: page 0 holds 17 bytes");

  odid_build_auth_page(m, &s, 1, 1, data, 64, 0);
  CHECK((m[1] & 0x0F) == 1, "auth: page 1 number");
  CHECK(memcmp(m + 2, data + 17, 23) == 0, "auth: page 1 holds 17..39");

  odid_build_auth_page(m, &s, 1, 2, data, 64, 0);
  CHECK(memcmp(m + 2, data + 40, 23) == 0, "auth: page 2 holds 40..62");

  odid_build_auth_page(m, &s, 1, 3, data, 64, 0);
  CHECK(m[2] == data[63], "auth: page 3 holds the final byte");
  CHECK(m[3] == 0, "auth: page 3 zero-pads past the data");

  // Length is a uint8 on the wire, so it saturates instead of wrapping.
  odid_build_auth_page(m, &s, 1, 0, data, 300, 0);
  CHECK(m[3] == 255, "auth: length clamps at 255");
}

// The System timestamp field is F3411-22a (v2) only.
static void test_version_gating(void) {
  OdidTxState s;
  memset(&s, 0, sizeof(s));
  s.uas_id = "VERSION-TEST";
  s.self_desc = "v";
  s.op_id = "OP";
  uint8_t pack[256];
  OdidUas u;

  s.proto_ver = 2;
  int n = odid_build_pack(pack, &s, 238000000u);
  CHECK((pack[0] & 0x0F) == 2, "version: pack header carries v2");
  CHECK(odid_decode_payload(pack, n, &u), "version: v2 decodes");
  CHECK(u.sys_ts == 238000000u, "version: v2 keeps the system timestamp");

  s.proto_ver = 0;
  n = odid_build_pack(pack, &s, 238000000u);
  CHECK((pack[0] & 0x0F) == 0, "version: pack header carries v0");
  CHECK((pack[3] & 0x0F) == 0, "version: messages carry v0 too");
  CHECK(odid_decode_payload(pack, n, &u), "version: v0 decodes");
  CHECK(u.sys_ts == 0, "version: v0 omits the v2-only system timestamp");
  CHECK_S(u.uas_id[0], "VERSION-TEST", "version: v0 identity intact");
}

// A CAA registration lands in the second Basic ID slot, and a pack never
// exceeds nine messages.
static void test_dual_basic_and_pack_limit(void) {
  OdidTxState s;
  memset(&s, 0, sizeof(s));
  s.proto_ver = 2;
  s.uas_id = "SERIAL-1";
  s.caa_id = "CAA-REG-1";
  s.self_desc = "d";
  s.op_id = "OP";

  uint8_t pack[256];
  int n = odid_build_pack(pack, &s, 0);
  CHECK(pack[2] == 6, "dual: pack holds six messages");
  CHECK(pack[2] <= ODID_PACK_MAX_MESSAGES, "dual: within the nine limit");

  OdidUas u;
  CHECK(odid_decode_payload(pack, n, &u), "dual: decodes");
  CHECK(u.has_basic[0] && u.has_basic[1], "dual: both Basic ID slots filled");
  CHECK(u.id_type[0] == 1 && u.id_type[1] == 2, "dual: serial then CAA");
  CHECK_S(u.uas_id[1], "CAA-REG-1", "dual: registration in slot 1");
}

// Single-message mode rotates through the five message types.
static void test_single_message_rotation(void) {
  OdidTxState s;
  memset(&s, 0, sizeof(s));
  s.proto_ver = 2;
  s.uas_id = "ROTATE-1";
  s.self_desc = "r";
  s.op_id = "OP-R";
  uint8_t m[25];
  const uint8_t want[5] = {0, 1, 3, 4, 5};
  for (int i = 0; i < 5; i++) {
    int n = odid_build_single(m, &s, 0, i);
    CHECK(n == ODID_MSG_SIZE, "single: one message");
    CHECK((m[0] >> 4) == want[i], "single: rotation order");
  }
}

int main(void) {
  test_golden_pack();
  test_tx_roundtrip();
  test_auth_pages();
  test_version_gating();
  test_dual_basic_and_pack_limit();
  test_single_message_rotation();
  test_location_scales();
  test_basic_id_utm_uuid();
  test_text_sanitization();
  test_pack_bounds();
  test_dual_basic_id();
  printf("%d passed, %d failed\n", g_pass, g_fail);
  return g_fail ? 1 : 0;
}
