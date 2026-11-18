// Ed25519 signing for the Authentication (type 2) message.
//
// The ASTM F3411 Authentication message carries a signature but the
// standard does not publish a canonical byte string to sign, so this signs
// the Basic ID message followed by the page-0 timestamp — the two things a
// verifier holding our public key already has. Document it, because a
// verifier must reproduce it exactly.
//
// The keypair is derived from a FIXED, PUBLISHED test seed: this is test
// equipment, and the point is that anyone can verify our signatures. It is
// not, and must never be, a manufacturer or operator key.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <stdint.h>
#include <string.h>
#include "monocypher.h"

// "orecchino-esp32 test beacon key, not for real aircraft" (SHA-free: the
// seed is the literal ASCII below, padded to 32 bytes).
static const uint8_t ODID_TEST_SEED[32] =
    "orecchino test key - NOT REAL\0\0";

static uint8_t s_auth_pub[32];
static uint8_t s_auth_sec[32];

static inline void odid_auth_init() {
  memcpy(s_auth_sec, ODID_TEST_SEED, 32);
  crypto_sign_public_key(s_auth_pub, s_auth_sec);
}

static inline const uint8_t* odid_auth_pubkey() {
  return s_auth_pub;
}

/// Sign `basic_id_msg` (25 bytes) plus the 4-byte little-endian timestamp.
/// Writes 64 bytes into `sig_out`.
static inline void odid_auth_sign(uint8_t* sig_out,
                                  const uint8_t* basic_id_msg,
                                  uint32_t timestamp) {
  uint8_t buf[ODID_MSG_SIZE + 4];
  memcpy(buf, basic_id_msg, ODID_MSG_SIZE);
  buf[ODID_MSG_SIZE + 0] = (uint8_t)(timestamp & 0xFF);
  buf[ODID_MSG_SIZE + 1] = (uint8_t)((timestamp >> 8) & 0xFF);
  buf[ODID_MSG_SIZE + 2] = (uint8_t)((timestamp >> 16) & 0xFF);
  buf[ODID_MSG_SIZE + 3] = (uint8_t)((timestamp >> 24) & 0xFF);
  crypto_sign(sig_out, s_auth_sec, s_auth_pub, buf, sizeof(buf));
}

/// True when the signature verifies — used by the on-device self-test so a
/// broken signing path can never ship silently.
static inline bool odid_auth_verify(const uint8_t* sig,
                                    const uint8_t* basic_id_msg,
                                    uint32_t timestamp) {
  uint8_t buf[ODID_MSG_SIZE + 4];
  memcpy(buf, basic_id_msg, ODID_MSG_SIZE);
  buf[ODID_MSG_SIZE + 0] = (uint8_t)(timestamp & 0xFF);
  buf[ODID_MSG_SIZE + 1] = (uint8_t)((timestamp >> 8) & 0xFF);
  buf[ODID_MSG_SIZE + 2] = (uint8_t)((timestamp >> 16) & 0xFF);
  buf[ODID_MSG_SIZE + 3] = (uint8_t)((timestamp >> 24) & 0xFF);
  return crypto_check(sig, s_auth_pub, buf, sizeof(buf)) == 0;
}
