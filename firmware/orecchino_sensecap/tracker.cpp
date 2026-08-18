#include "tracker.h"

Track g_tracks[TRK_MAX];

Track* tracker_upsert(const uint8_t* mac, const char* uas, uint32_t now,
                      bool* created) {
  if (created) *created = false;
  Track* by_uas = nullptr;
  Track* by_mac = nullptr;
  Track* free_slot = nullptr;
  Track* oldest = nullptr;
  for (int i = 0; i < TRK_MAX; i++) {
    Track* t = &g_tracks[i];
    if (!t->used) {
      if (!free_slot) free_slot = t;
      continue;
    }
    if (uas && uas[0] && strncmp(t->uas, uas, sizeof(t->uas)) == 0) by_uas = t;
    if (memcmp(t->mac, mac, 6) == 0) by_mac = t;
    if (!oldest || t->last_ms < oldest->last_ms) oldest = t;
  }
  // Identity wins over hardware address. Falling back to the MAC is only
  // safe when there is no identity conflict — otherwise two aircraft that
  // share a MAC (randomised addresses, a spoofer, or one transmitter
  // sending several UAS IDs) collapse into a single contact whose ID
  // flip-flops, hiding one of them entirely.
  Track* t = by_uas;
  if (!t && by_mac && (!uas || !uas[0] || !by_mac->uas[0])) t = by_mac;
  if (!t) {
    t = free_slot ? free_slot : oldest;   // LRU eviction, never slot 0 forever
    memset(t, 0, sizeof(*t));
    t->used = true;
    t->first_ms = now;
    t->height = NAN;
    t->speed = NAN;
    t->heading = NAN;
    t->max_height = NAN;
    t->peak_rssi = -127;
    if (created) *created = true;
  }
  memcpy(t->mac, mac, 6);
  if (uas && uas[0]) {
    strncpy(t->uas, uas, sizeof(t->uas) - 1);
    t->uas[sizeof(t->uas) - 1] = 0;
  }
  t->last_ms = now;
  t->msgs++;
  return t;
}

void tracker_expire(uint32_t now) {
  for (int i = 0; i < TRK_MAX; i++) {
    if (g_tracks[i].used && now - g_tracks[i].last_ms > TRK_EXPIRE_MS)
      g_tracks[i].used = false;
  }
}

int tracker_count() {
  int n = 0;
  for (int i = 0; i < TRK_MAX; i++)
    if (g_tracks[i].used) n++;
  return n;
}
