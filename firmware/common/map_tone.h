// map_tone.h — basemap tiles re-toned for the T5's 16-grey e-paper as a
// printed street map: land is paper, streets dark lines, water a light
// tint, labels black. Two palettes, one per source (tile_path.h):
//
//   map_tone_esri   Esri World Dark Gray Canvas (JPEG, the basemap now).
//                   Measured on San Francisco tiles z12-15 (luma, 0-255):
//                   water ~34, land and blocks 64-86, streets 90-110,
//                   major roads and the base layer's own street labels
//                   brighter (120-161). JPEG ringing spreads each class by a
//                   few steps; the thresholds sit between the clusters.
//   map_tone_carto  CARTO dark_all (PNG; the SenseCAP's bundled pack, and
//                   any genuine older tiles): land 9, streets 17-29, water 34.
//
// Tones are the panel's greys (0 black .. 15 white), from the range it
// shows distinctly (3-10) plus white paper. Pure C: tests/tile_image_test.cpp
// runs it on real decoded tiles.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <stdint.h>

static inline uint8_t map_tone_esri(int luma) {
  if (luma <= 48)  return 9;    // water
  if (luma <= 60)  return 12;   // shoreline, dark landuse
  if (luma <= 88)  return 15;   // land and blocks: paper
  if (luma <= 114) return 6;    // streets
  if (luma <= 128) return 4;    // major roads
  return 0;                     // labels, highways
}

static inline uint8_t map_tone_carto(int luma) {
  if (luma <= 6)  return 10;   // buildings, major-road fill
  if (luma <= 11) return 15;   // land
  if (luma <= 14) return 12;   // landuse variants
  if (luma <= 18) return 7;    // paths, street edges
  if (luma <= 23) return 6;
  if (luma <= 31) return 5;    // streets, road casings
  if (luma <= 40) return 8;    // water
  if (luma <= 54) return 3;    // label edges
  return 0;                    // label text
}
