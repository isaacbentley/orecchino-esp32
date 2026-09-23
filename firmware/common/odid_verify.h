// Ed25519 verification of ASTM F3411 Authentication messages.
//
// The standard does not publish a canonical byte string to sign, so a
// verifier has to know what its transmitter signed. This checks the
// convention orecchino_tx uses — the Basic ID message followed by the
// page-0 timestamp, little-endian — against the keys it knows.
//
// THE ONLY KEY IT KNOWS IS A TEST KEY. orecchino_tx signs with a keypair
// whose seed is published in this repository (odid_auth.h), so anyone can
// sign any ID with it. A signature under that key is reported as its own
// state, test_key, which a UI shows neutrally ("TEST KEY"), never as the
// green of a verified identity. A build that wants the bench beacon to read
// id_valid (to exercise that path of a UI) defines ORECCHINO_TRUST_TEST_KEY.
//
// WHAT A PASS DOES AND DOES NOT MEAN. The signature covers the Basic ID
// and a timestamp: nothing else. It says "this ID was signed by a key we
// trust". It says nothing about where the aircraft is — the Location
// message is unsigned, so a captured ID+Auth pair can be replayed beside
// a fabricated position and still pass. Nor is there replay protection:
// the timestamp is signed but never checked for freshness, so a recorded
// pair verifies forever. Hence the state is named id_valid, not valid;
// never let a UI upgrade it into a blanket badge of trust, and never let
// it colour the position fields.
//
// Receivers that decode auth at all are rare; ones that verify are rarer
// still. Include this only where monocypher is also compiled in.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <stdint.h>
#include <string.h>
#include "odid_decode.h"
#include "monocypher.h"

// What a verified signature does and does not mean: the signature covers
// the UAS *ID*, not the position, and nothing here rejects a replayed old
// signature. "id_valid" says the ID was signed by a trusted key — never
// that the aircraft is where it claims to be.
// Numbered as sent to the apps and stored in match-log records: append
// only. Everything >= ODID_AUTH_UNKNOWN_KEY is a complete signature set.
typedef enum {
  ODID_AUTH_NONE = 0,     // no Authentication messages received
  ODID_AUTH_PARTIAL,      // pages still missing
  ODID_AUTH_UNKNOWN_KEY,  // complete, but signed by a key we do not hold
  ODID_AUTH_ID_VALID,     // signature over the ID verifies — see file header
  ODID_AUTH_INVALID,      // signature does not verify
  ODID_AUTH_TEST_KEY,     // verifies under the published test key: proves nothing
} OdidAuthState;

static inline const char* odid_auth_state_name(OdidAuthState s) {
  switch (s) {
    case ODID_AUTH_ID_VALID:    return "id_valid";
    case ODID_AUTH_INVALID:     return "invalid";
    case ODID_AUTH_PARTIAL:     return "partial";
    case ODID_AUTH_UNKNOWN_KEY: return "unknown_key";
    case ODID_AUTH_TEST_KEY:    return "test_key";
    default:                    return "none";
  }
}

// Public key of orecchino_tx's published test keypair (seed in odid_auth.h).
// Known, not trusted: see the file header.
static const uint8_t ODID_TEST_PUBKEY[32] = {
  0xe3, 0x28, 0x4b, 0x2c, 0x7f, 0xb0, 0x03, 0x38,
  0x03, 0x7f, 0x8d, 0x2b, 0xc1, 0x4a, 0x75, 0x27,
  0x66, 0x86, 0xe7, 0x7d, 0xd1, 0xf7, 0xfb, 0xff,
  0x95, 0x55, 0x22, 0x0f, 0x5e, 0xca, 0x6d, 0x49,
};

/// Verify a completed auth set against the trusted keys. A pass attests
/// the ID binding only — read the caveats at the top of this file before
/// showing the result to anyone.
static inline OdidAuthState odid_verify_auth(const OdidUas* u) {
  if (!u->has_auth) return ODID_AUTH_NONE;
  if (!odid_auth_complete(u)) return ODID_AUTH_PARTIAL;
  if (u->auth_len != 64) return ODID_AUTH_UNKNOWN_KEY;  // not an Ed25519 sig
  if (!u->has_basic_raw) return ODID_AUTH_PARTIAL;      // nothing to bind to

  uint8_t buf[25 + 4];
  memcpy(buf, u->basic_raw, 25);
  buf[25] = (uint8_t)(u->auth_ts & 0xFF);
  buf[26] = (uint8_t)((u->auth_ts >> 8) & 0xFF);
  buf[27] = (uint8_t)((u->auth_ts >> 16) & 0xFF);
  buf[28] = (uint8_t)((u->auth_ts >> 24) & 0xFF);

  if (crypto_check(u->auth_data, ODID_TEST_PUBKEY, buf, sizeof(buf)) == 0) {
#if defined(ORECCHINO_TRUST_TEST_KEY)
    return ODID_AUTH_ID_VALID;
#else
    return ODID_AUTH_TEST_KEY;
#endif
  }
  // A well-formed signature that matches no key we hold is reported as
  // invalid rather than unknown: with one key configured, the honest
  // reading of a mismatch is "this is not who it claims to be".
  return ODID_AUTH_INVALID;
}
