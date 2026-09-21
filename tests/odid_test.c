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

  // Auth-only frame decodes and sets has_auth for cross-frame assembly
  memset(d, 0, sizeof(d));
  d[0] = 0x22;  // Auth message
  CHECK(odid_decode_payload(d, 25, &u), "bounds: auth-only accepted");
  CHECK(u.has_auth, "bounds: auth flag set");

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

  // LastPageIndex is attacker-controlled: anything past the 4-bit page
  // range must be clamped, or odid_auth_complete() shifts by >= the width
  // of its operand. Pair it with a Basic ID so the pack decodes at all.
  memset(d, 0, sizeof(d));
  d[0] = 0xF2;
  d[1] = 25;
  d[2] = 2;
  d[3] = 0x02;                 // Basic ID, serial
  d[4] = 0x12;
  d[5] = 'Y';
  d[3 + 25] = 0x22;            // Auth, page 0
  d[3 + 25 + 1] = 0x10;        // auth type 1, page 0
  d[3 + 25 + 2] = 0xFF;        // LastPageIndex: hostile
  d[3 + 25 + 3] = 64;          // total length
  CHECK(odid_decode_payload(d, 3 + 50, &u), "auth: hostile page index decodes");
  CHECK(u.auth_last_page <= 15, "auth: LastPageIndex clamped to 4 bits");
  CHECK(!odid_auth_complete(&u), "auth: one page of many is not complete");
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

// Standalone Authentication messages (e.g. from single-message rotation or individual frames)
// must decode cleanly.
static void test_standalone_auth_decoding(void) {
  OdidTxState s;
  memset(&s, 0, sizeof(s));
  s.proto_ver = 2;
  uint8_t m[25];
  uint8_t sig[64] = {0};
  odid_build_auth_page(m, &s, 1, 0, sig, sizeof(sig), 12345);

  OdidUas u;
  CHECK(odid_decode_payload(m, sizeof(m), &u), "standalone auth: decodes payload");
  CHECK(u.has_auth, "standalone auth: has_auth true");
  CHECK(u.auth_type == 1, "standalone auth: auth_type 1");
  CHECK(u.auth_ts == 12345, "standalone auth: timestamp preserved");
  CHECK(u.auth_pages_seen == 1, "standalone auth: page 0 seen");
}

static void unhex(const char* h, uint8_t* out) {
  for (int i = 0; h[i] && h[i + 1]; i += 2) {
    char t[3] = { h[i], h[i + 1], 0 };
    out[i / 2] = (uint8_t)strtoul(t, NULL, 16);
  }
}

// A real DJI beacon (Light RID Scanner's capture, GPL-3.0): protocol v1
// pack of Basic ID, Location and System from a Matrice 400, SSID
// "RID-1581F8DBW25B800B3417".
static void test_dji_v1_capture(void) {
  uint8_t d[78];
  unhex("f11903011231353831463844425732354238303042333431370000001120ac1600a3d4ea11cbfe3c48"
        "e2089e0879082c04c6250a004109ffeeea1199b73d4801000000000000020008d774da0d00", d);
  OdidUas u;
  CHECK(odid_decode_payload(d, 78, &u), "dji: pack decodes");
  CHECK(u.proto_ver == 1 && !u.gb46750, "dji: protocol v1, not GB");
  CHECK(u.has_basic[0] && u.id_type[0] == 1 && u.ua_type[0] == 2, "dji: serial-number basic id, multirotor");
  CHECK_S(u.uas_id[0], "1581F8DBW25B800B3417", "dji: serial");
  CHECK(u.has_loc && u.status == 2, "dji: airborne location");
  CHECK_F(u.dir, 172.0, 0.01, "dji: direction");
  CHECK_F(u.speed, 5.5, 0.01, "dji: speed");
  CHECK_F(u.vspeed, 0.0, 0.01, "dji: vertical speed");
  CHECK_F(u.lat, 30.0602531, 1e-7, "dji: latitude");
  CHECK_F(u.lon, 121.1956939, 1e-7, "dji: longitude");
  CHECK_F(u.alt_baro, 137.0, 0.01, "dji: baro altitude");
  CHECK_F(u.alt_geo, 103.0, 0.01, "dji: geodetic altitude");
  CHECK_F(u.height, 84.5, 0.01, "dji: height");
  CHECK(u.height_ref == 0, "dji: height above take-off");
  CHECK(u.h_acc == 12 && u.v_acc == 2 && u.ts_acc == 10, "dji: accuracies");
  CHECK_F(u.ts, 967.0, 0.01, "dji: timestamp");
  CHECK(u.has_sys && u.op_loc_type == 1 && u.area_count == 1, "dji: system message");
  CHECK_F(u.op_lat, 30.0609279, 1e-7, "dji: operator latitude");
  CHECK_F(u.op_lon, 121.2004249, 1e-7, "dji: operator longitude");
  CHECK_F(u.op_alt, 24.0, 0.01, "dji: operator altitude");
  CHECK(u.sys_ts == 232420567, "dji: system timestamp");
  CHECK(!u.has_self && !u.has_op && !u.has_auth, "dji: nothing else claimed");
}

// GB 46750-2025 standard packet from a DJI Mini 5 Pro (Light RID Scanner's
// capture): every one of the 21 items present.
static void test_gb46750_standard_packet(void) {
  uint8_t d[78];
  unhex("ff2048fffffe3135383146414e4c433235385530323952544e363030303030303030000101d1823b48"
        "3bf2eb11ed0769833b4822f0eb1105001c00284700c2083d0902000c050478acc5529e0103", d);
  OdidUas u;
  CHECK(odid_decode_payload(d, 78, &u), "gb: packet decodes");
  CHECK(u.gb46750, "gb: flagged as GB 46750");
  CHECK(u.has_basic[0] && u.id_type[0] == 1, "gb: serial-number basic id");
  CHECK_S(u.uas_id[0], "1581FANLC258U029RTN6", "gb: serial");
  CHECK(!u.has_basic[1], "gb: an all-zero registration mark is not an id");
  CHECK(u.has_loc && u.status == 2, "gb: airborne location");
  CHECK_F(u.lat, 30.0675106, 1e-7, "gb: aircraft latitude");
  CHECK_F(u.lon, 121.1859817, 1e-7, "gb: aircraft longitude");
  CHECK_F(u.dir, 0.5, 0.01, "gb: track");
  CHECK_F(u.speed, 2.8, 0.01, "gb: ground speed");
  CHECK_F(u.height, 108.0, 0.01, "gb: relative altitude");
  CHECK(u.height_ref == 0, "gb: relative altitude is above take-off");
  CHECK_F(u.vspeed, 0.0, 0.01, "gb: vertical speed");
  CHECK_F(u.alt_geo, 121.0, 0.01, "gb: geodetic altitude");
  CHECK_F(u.alt_baro, 182.5, 0.01, "gb: barometric altitude");
  CHECK(u.h_acc == 12 && u.v_acc == 5 && u.spd_acc == 4 && u.ts_acc == 3, "gb: accuracies");
  CHECK_F(u.ts, 3547.0, 0.01, "gb: seconds into the hour");
  CHECK(u.sys_ts == 233204347, "gb: timestamp since 2019");
  CHECK(u.has_sys && u.op_loc_type == 1, "gb: live remote-station position");
  CHECK_F(u.op_lat, 30.0675643, 1e-7, "gb: operator latitude");
  CHECK_F(u.op_lon, 121.1859665, 1e-7, "gb: operator longitude");
  CHECK_F(u.op_alt, 14.5, 0.01, "gb: operator altitude");
}

// The Light RID Scanner project's synthetic GB packet: a registration mark
// that counts, a content length longer than the frame, unknown altitudes.
static void test_gb46750_registration_and_truncation(void) {
  uint8_t d[67];
  unhex("ff2048fffffe31353831463844425732354238303042333431375541534944313233000000cbfe3c48"
        "a3d4ea11000099b73d48ffeeea11000000000000000000000000", d);
  OdidUas u;
  CHECK(odid_decode_payload(d, 67, &u), "gb2: truncated packet still decodes what arrived");
  CHECK_S(u.uas_id[0], "1581F8DBW25B800B3417", "gb2: serial");
  CHECK(u.has_basic[1] && u.id_type[1] == 2, "gb2: registration mark as a CAA-type id");
  CHECK_S(u.uas_id[1], "UASID123", "gb2: registration mark");
  CHECK_F(u.op_lat, 30.0602531, 1e-7, "gb2: operator latitude from item 6");
  CHECK_F(u.op_lon, 121.1956939, 1e-7, "gb2: operator longitude");
  CHECK_F(u.lat, 30.0609279, 1e-7, "gb2: aircraft latitude from item 8");
  CHECK_F(u.lon, 121.2004249, 1e-7, "gb2: aircraft longitude");
  CHECK(u.alt_geo == -1000.0f && u.height == -1000.0f, "gb2: zero altitudes stay unknown");
  CHECK(u.status == 0, "gb2: status undeclared");
  // A six-byte item bitmap (three extension bytes carrying nothing) must
  // be consumed whole, not read as content.
  uint8_t e[81];
  unhex("ff2048ffffff0101003135383146414e4c433235385530323952544e363030303030303030000101d1823b48"
        "3bf2eb11ed0769833b4822f0eb1105001c00284700c2083d0902000c050478acc5529e0103", e);
  CHECK(odid_decode_payload(e, 81, &u) && !strcmp(u.uas_id[0], "1581FANLC258U029RTN6") &&
        fabs(u.lat - 30.0675106) < 1e-7, "gb2: a longer bitmap still lands on the content");
  uint8_t f[9];
  unhex("ff2048ffffffffffff", f);        // bitmap never terminates
  CHECK(!odid_decode_payload(f, 9, &u), "gb2: an unterminated bitmap is rejected");
  // Not a GB packet: an ODID pack header with a bad message size still fails.
  uint8_t bad[25] = {0xF2, 0x20, 0x01};
  CHECK(!odid_decode_payload(bad, 25, &u), "gb2: ODID pack with wrong size still rejected");
}

static void test_coord_plausibility(void) {
  CHECK(!odid_coord_plausible(0, 0), "coord: 0,0 is no fix");
  CHECK(!odid_coord_plausible(1e-7, -1e-7), "coord: sentinel near zero is no fix");
  CHECK(!odid_coord_plausible(4.9, 4.9), "coord: inside the 5-degree band");
  CHECK(odid_coord_plausible(5.6, -0.2), "coord: Accra is a real place");
  CHECK(odid_coord_plausible(37.8, -122.4), "coord: San Francisco");
  CHECK(!odid_coord_plausible(91, 0) && !odid_coord_plausible(0, 181), "coord: off the globe");
  CHECK(!odid_coord_plausible(0.0 / 0.0, 10), "coord: NaN");
}

int main(void) {
  test_dji_v1_capture();
  test_gb46750_standard_packet();
  test_gb46750_registration_and_truncation();
  test_coord_plausibility();
  test_golden_pack();
  test_tx_roundtrip();
  test_auth_pages();
  test_version_gating();
  test_dual_basic_and_pack_limit();
  test_single_message_rotation();
  test_standalone_auth_decoding();
  test_location_scales();
  test_basic_id_utm_uuid();
  test_text_sanitization();
  test_pack_bounds();
  test_dual_basic_id();
  printf("%d passed, %d failed\n", g_pass, g_fail);
  return g_fail ? 1 : 0;
}
