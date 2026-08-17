# Third-party components and licenses

Compiled into or referenced by this project. Audited 2026-08-17.

## Firmware libraries (linked at build time, not vendored)

| Component | License | Use |
| --- | --- | --- |
| [NimBLE-Arduino](https://github.com/h2zero/NimBLE-Arduino) | Apache-2.0 | BLE host, extended/coded-PHY scanning |
| [Arduino_GFX](https://github.com/moononournation/Arduino_GFX) | BSD-style (`license.txt`) | RGB panel driver, canvases, ST7701 init table |
| [Adafruit GFX Library](https://github.com/adafruit/Adafruit-GFX-Library) | BSD | `Fonts/` headers only (see fonts note) |
| [PNGdec](https://github.com/bitbank2/PNGdec) | Apache-2.0 | Map tile decoding |
| [PCA95x5](https://github.com/hideakitai/PCA95x5) | MIT | TCA9535 IO expander |
| [arduino-esp32](https://github.com/espressif/arduino-esp32) / ESP-IDF | LGPL-2.1 / Apache-2.0 | Core, WiFi promiscuous, radio stacks |

## Vendored / derived code

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
