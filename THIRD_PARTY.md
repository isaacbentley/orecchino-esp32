# Third-party components and licenses

Compiled into or referenced by this project. Audited 2026-08-17.

## Firmware libraries (linked at build time, not vendored)

| Component | License | Use |
| --- | --- | --- |
| [NimBLE-Arduino](https://github.com/h2zero/NimBLE-Arduino) | Apache-2.0 | BLE host, extended/coded-PHY scanning |
| [Arduino_GFX](https://github.com/moononournation/Arduino_GFX) | BSD-style (`license.txt`) | Panel drivers (ST7701 RGB, ST7789 SPI, SH8601 QSPI), canvases |
| [Adafruit GFX Library](https://github.com/adafruit/Adafruit-GFX-Library) | BSD | `Fonts/` headers only, on every board with a screen (see fonts note) |
| [PNGdec](https://github.com/bitbank2/PNGdec) | Apache-2.0 | Map tile decoding |
| [PCA95x5](https://github.com/hideakitai/PCA95x5) | MIT | TCA9535 IO expander |
| [arduino-esp32](https://github.com/espressif/arduino-esp32) / ESP-IDF | LGPL-2.1 / Apache-2.0 | Core, WiFi promiscuous, radio stacks |

## Vendored / derived code

- `firmware/libraries/Monocypher/` — [Monocypher](https://monocypher.org)
  3.1.2 (BSD-2-Clause OR CC0-1.0), vendored unmodified. Ed25519 signing for
  the test beacon's Authentication messages.
- `firmware/libraries/epdiy/` — [epdiy](https://github.com/vroland/epdiy)
  2.1.3 (LGPL-3.0-or-later), vendored unmodified: `src/`, its
  `library.properties`, `LICENSE` and `README.md`. Drives the T5 E-Paper
  S3 Pro's ED047TC1 panel as an epdiy v7 board. LGPL-3.0 is compatible
  with this project's GPL-3.0-or-later. (LilyGO's own fork of epdiy 2.0.0
  targets ESP-IDF 4.x and does not build on the current Arduino core.)
- `firmware/orecchino_tembed/`, `firmware/orecchino_t5epd/`,
  `firmware/orecchino_amoled/` — written for this project. Pin and
  power-sequence facts come from the vendors' MIT-licensed example code:
  LilyGO's [T-Embed-CC1101](https://github.com/Xinyuan-LilyGO/T-Embed-CC1101)
  and [T5S3-4.7-e-paper-PRO](https://github.com/Xinyuan-LilyGO/T5S3-4.7-e-paper-PRO),
  and Waveshare's
  [ESP32-C6-Touch-AMOLED-1.8](https://github.com/waveshareteam/ESP32-C6-Touch-AMOLED-1.8).
  The CC1101 and SX1262 sweep drivers are register-level code written from
  the datasheets, not copied from any driver library.
- `firmware/orecchino_t5epd/t5_periph.cpp` — written for this project.
  The Goodix touch protocols (GT911's 16-bit register map; the GT6972P's
  32-bit "Berlin" map, boot-option handshake and IC-info block layout) are
  interface facts taken from Goodix's public Linux drivers and from LilyGO's
  `GoodixGT6972P` example library. That library is GPL-2.0-only, which is
  not compatible with this project's GPL-3.0-or-later, so **no code from it
  is vendored or copied** — only the register facts. The BQ27220 and PCA9555
  accesses are from their datasheets.
- `firmware/orecchino_sensecap/IndicatorBus.{h,cpp}` — written for this
  project; the `Arduino_DataBus` interface it implements follows
  Arduino_GFX's `Arduino_SWSPI` (BSD), and the SenseCAP Indicator pin/reset
  facts come from Seeed's Apache-2.0
  [SenseCAP_Indicator_ESP32](https://github.com/Seeed-Solution/SenseCAP_Indicator_ESP32)
  BSP. (An earlier revision vendored `Indicator_SWSPI`/`Indicator_Extender`
  from LongDirtyAnimAlf/SenseCap, which carries **no license** — those files
  were removed and replaced before any public release.)

## Fonts

The `FreeSansBold*` headers from Adafruit's `Fonts/` directory are
conversions of **GNU FreeFont**, licensed GPLv3 **with the font-embedding
exception** — embedding them in a program does not impose the GPL on the
program. Compatible with either a GPL or permissive license for this repo.

## Test vectors

`tests/vectors/` contains reference captures and the Lua dissector from
[opendroneid/wireshark-dissector](https://github.com/opendroneid/wireshark-dissector)
(Apache-2.0), used as the independent ground truth for the decoder tests —
the golden values in `tests/odid_test.c` were cross-checked against that
dissector's output (one Lua 5.4 compatibility fix applied locally).

## Data

- **Map tiles are not distributed in this repo.** `tools/fetch_tiles.py`
  downloads CARTO `dark_all` raster tiles for personal/offline use:
  map data © OpenStreetMap contributors (ODbL), tiles © CARTO, subject to
  CARTO's basemap terms. For redistribution or heavier use, generate tiles
  from OSM data or self-host (e.g. Protomaps/OpenMapTiles) instead.
- **FAA TFR polygons** (macOS app) are fetched live from tfr.faa.gov
  (US-government data, public domain).

## Specifications

The ASTM F3411 / Open Drone ID message layouts were implemented from the
public specification; no decoder code was copied from other projects.
