# Third-party components and licenses

Compiled into or referenced by this project. Audited 2026-09-25.

## Firmware libraries (linked at build time, not vendored)

Versions as pinned in `.github/workflows/ci.yml` (`arduino-cli lib install`
and `ESP32_CORE`).

| Component | Version | License | Use |
| --- | --- | --- | --- |
| [NimBLE-Arduino](https://github.com/h2zero/NimBLE-Arduino) | 2.5.1 | Apache-2.0 | BLE host, extended/coded-PHY scanning |
| [Arduino_GFX](https://github.com/moononournation/Arduino_GFX) ("GFX Library for Arduino") | 1.6.7 | BSD-style (`license.txt`) | Panel drivers (ST7701 RGB, ST7789 SPI, SH8601 QSPI), canvases |
| [Adafruit GFX Library](https://github.com/adafruit/Adafruit-GFX-Library) | 1.12.6 | BSD | `Fonts/` headers only, on every board with a screen (see fonts note) |
| [Adafruit BusIO](https://github.com/adafruit/Adafruit_BusIO) | 1.17.4 | MIT | Compiled only because Adafruit GFX's `Adafruit_SPITFT.cpp` includes it; nothing here calls it |
| [PNGdec](https://github.com/bitbank2/PNGdec) | 1.1.6 | Apache-2.0 | Map tile decoding (older `.png` tiles) |
| [PCA95x5](https://github.com/hideakitai/PCA95x5) | 0.1.3 | MIT | TCA9535 IO expander |
| [arduino-esp32](https://github.com/espressif/arduino-esp32) / ESP-IDF | 3.3.11 | LGPL-2.1 / Apache-2.0 | Core, WiFi promiscuous, radio stacks; on the T5 also `esp_http_client`, mbedTLS and the ESP-IDF root certificate bundle (`esp_crt_bundle`: Mozilla's CA list, MPL-2.0) for the Wi-Fi fetches |

## Phone app (`mobile/`, Flutter packages fetched by `flutter pub get`, not vendored)

Versions as locked in `mobile/pubspec.lock`; licenses read from each
package's `LICENSE` in the pub cache. All are GPL-compatible.

| Package | Version | License | Use |
| --- | --- | --- | --- |
| [Flutter](https://github.com/flutter/flutter) SDK (framework, engine) | pubspec ≥ 3.27; the lock file resolves to Dart ≥ 3.11 / Flutter ≥ 3.38.4 (CI: 3.47.5) | BSD-3-Clause | UI toolkit |
| [flutter_blue_plus](https://pub.dev/packages/flutter_blue_plus) (+ `_android`, `_darwin`, `_platform_interface`) | 1.36.8 | BSD-3-Clause | BLE central: scan, bond, NUS link |
| [drift](https://pub.dev/packages/drift) | 2.35.0 | MIT | Local database (history, detectors, settings) |
| [sqlite3](https://pub.dev/packages/sqlite3), [sqlite3_flutter_libs](https://pub.dev/packages/sqlite3_flutter_libs) | 3.5.2, 0.5.42 | MIT (bundles SQLite, public domain) | SQLite for drift |
| [geolocator](https://pub.dev/packages/geolocator) (+ platform packages) | 12.0.0 | MIT | Phone position |
| [flutter_compass](https://pub.dev/packages/flutter_compass) | 0.8.1 | MIT | Heading for the heading-up radar |
| [flutter_local_notifications](https://pub.dev/packages/flutter_local_notifications) (+ platform packages) | 22.3.1 | BSD-3-Clause | Traffic and drone alert notifications |
| [timezone](https://pub.dev/packages/timezone) | 0.11.1 | BSD-2-Clause | Pulled in by flutter_local_notifications |
| [flutter_tts](https://pub.dev/packages/flutter_tts) | 4.2.5 | MIT | Optional spoken traffic callout |
| [http](https://pub.dev/packages/http) | 1.6.0 | BSD-3-Clause | adsb.lol requests |
| [path_provider](https://pub.dev/packages/path_provider), [path](https://pub.dev/packages/path) | 2.1.6, 1.9.1 | BSD-3-Clause | Database location |
| [flutter_map](https://pub.dev/packages/flutter_map) | 8.3.2 | BSD-3-Clause | Live screen's Map mode |
| [latlong2](https://pub.dev/packages/latlong2) | 0.10.1 | Apache-2.0 | Coordinates for flutter_map |
| [dart_earcut](https://pub.dev/packages/dart_earcut), [dart_polylabel2](https://pub.dev/packages/dart_polylabel2) | 1.2.0, 1.0.0 | MIT; BSD-3-Clause plus ISC (© 2016 Mapbox, the polylabel it ports) | Pulled in by flutter_map (polygons) |
| [proj4dart](https://pub.dev/packages/proj4dart), [mgrs_dart](https://pub.dev/packages/mgrs_dart), [wkt_parser](https://pub.dev/packages/wkt_parser) | 3.0.0, 3.0.0, 2.0.0 | MIT | Pulled in by flutter_map / latlong2 (projections) |
| [unicode](https://pub.dev/packages/unicode), [simple_sparse_list](https://pub.dev/packages/simple_sparse_list) | 1.1.9, 0.1.4 | BSD-3-Clause | Pulled in by latlong2 |
| [archive](https://pub.dev/packages/archive), [posix](https://pub.dev/packages/posix) | 4.3.0, 6.5.2 | MIT | Pulled in by flutter_map's tile cache |
| [intl](https://pub.dev/packages/intl) | 0.20.3 | BSD-3-Clause | Pulled in by latlong2 and flutter_map |

The remaining transitive packages in the lock file are the Dart team's
BSD-3-Clause utilities and a few MIT, BSD-2-Clause and Apache-2.0 ones
(e.g. `rxdart` Apache-2.0, `uuid` MIT, `xml` MIT). Two are
MPL-2.0 — `bluez` and `dbus`, flutter_blue_plus's Linux backend — and are
only compiled into a Linux desktop build, which this project does not
ship; MPL-2.0 is GPL-compatible in any case. Build-time only (not shipped):
`build_runner`, `drift_dev`, `flutter_lints` (BSD-3-Clause / MIT).

The phone app does not yet show these packages' licence notices in-app
(nothing calls Flutter's `showLicensePage` or reads `LicenseRegistry`);
that is a follow-up, and until then this file is the notice that
accompanies the binaries.

Fonts bundled with the phone app (`mobile/assets/fonts/`, each folder with
its `OFL.txt`), all under the SIL Open Font License 1.1, which allows
bundling them in an app of any license:

| Font | Use | Copyright |
|---|---|---|
| [Space Grotesk](https://github.com/floriankarsten/space-grotesk) (variable) | Display type and large numbers | 2020 The Space Grotesk Project Authors |
| [Inter](https://github.com/rsms/inter) (variable, 4.001) | Text | 2016 The Inter Project Authors (the TTF's copyright line; its `OFL.txt` header says 2020) |
| [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono) (variable) | UAS IDs, MACs, hex | 2020 The JetBrains Mono Project Authors |
| [IBM Plex Sans Condensed](https://github.com/IBM/plex) 2.0.0 (Regular, SemiBold, Bold) | Flat theme: display type | 2017 IBM Corp., Reserved Font Name "Plex" |
| [IBM Plex Sans](https://github.com/IBM/plex) 1.1.0 (Regular, Medium, SemiBold, Bold) | Flat theme: text | 2017 IBM Corp., Reserved Font Name "Plex" |
| [IBM Plex Mono](https://github.com/IBM/plex) 2.5.0 (Regular, Medium, SemiBold, Bold) | Flat theme: identifiers, section heads | 2017 IBM Corp., Reserved Font Name "Plex" |

The IBM Plex files are the unmodified TTFs from the
[IBM/plex](https://github.com/IBM/plex/releases) monorepo's npm release
tags `@ibm/plex-sans-condensed@2.0.0`, `@ibm/plex-sans@1.1.0` and
`@ibm/plex-mono@2.5.0` (those are the package versions above; the TTFs'
own name tables say font versions 3.000, 3.005 and 2.005, copyright 2019,
2018 and 2017 IBM Corp.), only the weights the Flat theme uses. The 2017
in the table is the copyright line of each folder's `OFL.txt` and of the
release's `LICENSE.txt`.

The app icon and launch artwork (`mobile/branding/`) are original to this
project.

## Vendored / derived code

- `firmware/libraries/JPEGDEC/` — [JPEGDEC](https://github.com/bitbank2/JPEGDEC)
  1.8.4 by Larry Bank (Apache-2.0, `LICENSE`), unmodified: `src/`, its
  `library.properties`, `LICENSE` and `README.md` from the Arduino library
  release. Decodes the Esri JPEG map tiles: 8-bit grey on the T5, RGB565 on
  the SenseCAP, its ~18 KB of state in PSRAM. (`library.properties` lists
  `bb_spi_lcd` as a dependency; only its `JPEGDisplay.h`, which nothing here
  includes, uses it.) Apache-2.0 is compatible with this project's
  GPL-3.0-or-later.
- `firmware/libraries/Monocypher/` — [Monocypher](https://monocypher.org)
  3.1.2 (BSD-2-Clause OR CC0-1.0, `LICENSE`), vendored with one change,
  marked `orecchino:` in `src/monocypher.cpp` and noted in its
  `library.properties`: a
  `#pragma GCC optimize ("Os")` so the file builds for size even where a
  sketch asks for `-O2` (Ed25519 verification measured 24.2 ms at `-O2`,
  16.4 ms at `-Os` on an ESP32-S3). Ed25519 signing for the test beacon's
  Authentication messages and verification on the receivers.
- `firmware/libraries/epdiy/` — [epdiy](https://github.com/vroland/epdiy)
  2.1.3 (LGPL-3.0-or-later): `src/`, its `library.properties`, `LICENSE`
  and `README.md`. Drives the T5 E-Paper S3 Pro's ED047TC1 panel as an
  epdiy v7 board. LGPL-3.0 is compatible with this project's
  GPL-3.0-or-later. (LilyGO's own fork of epdiy 2.0.0 targets ESP-IDF 4.x
  and does not build on the current Arduino core.) Local patches, each
  marked "Orecchino patch" in the source:
  - `src/output_lcd/lcd_driver.{c,h}` and `render_lcd.c`: on the ESP32-S3
    the LCD output drove every waveform phase with one fixed CKV high time,
    ignoring the waveform's per-phase times, so ED047TC1's short
    grey-building pulses ran several times too long and grey 4 and up came
    out nearly white. The patch applies each phase's time, capped to fit a
    line, as epdiy's ESP32 output already does.
  - `src/render.c`: the two line-feeder tasks run at
    `EPD_FEED_TASK_PRIORITY` (19, overridable) instead of
    `configMAX_PRIORITIES - 1`. They busy-wait for a whole refresh, and at
    the top priority the one on core 0 starved the Wi-Fi and Bluetooth
    tasks, `esp_timer` (the channel hop) and the NimBLE host.
  - `src/output_lcd/render_lcd.c` (`lcd_calculate_frame`): a feeder now
    waits for room in its queue first, then claims a line number, computes
    and commits that line with its core's scheduler suspended (a few
    microseconds; interrupts still run). The frame starts exactly once per
    frame (`frame_started`, added to the render context): when the trigger
    line is committed, or as soon as a feeder finds its queue full first,
    and on the error path too. Upstream claimed the line first and then
    waited, so a feeder preempted by a radio task held a line the output
    interrupt needed and the refresh ended in "line buffer underrun" with
    the panel half driven.
  - `src/board/epd_board_v7.c`: board bring-up no longer aborts on an I2C
    error (`ESP_ERROR_CHECK` replaced by logged errors), pulls `CFG_INTR`
    up, gives the bus and the PCA9555 15 ms to settle, retries the PCA9555
    configuration up to five times with an `i2c_master_bus_reset` between
    tries, and bounds the two PWRGOOD waits (`epd_board_poweron`,
    `epd_board_measure_vcom`) to 200 tries of 1 ms instead of spinning
    forever.
  - `src/output_common/render_context.c`: `prepare_context_for_next_frame`
    clears the `frame_started` flag the `render_lcd.c` patch added.
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
  is vendored or copied** — only the register facts. The PCA9555 accesses
  are from its datasheet.
- `firmware/common/bq27220.h`, `bq27220_profiles.h`, `axp2101.h` — written
  for this project. The BQ27220 commands and register map are from TI's
  technical reference manual (SLUUBD4). The data-memory write sequence and
  the delays that work follow the behaviour documented in Flipper Zero's
  GPL-3.0 driver (`lib/drivers/bq27220.c`); no code from it is copied. The
  per-board discharge profiles are the values LilyGO publishes for each
  board (`lib/BQ27220/bq27220_data_memory.c` in its T5S3-4.7-e-paper-PRO
  and T-Embed-CC1101 repositories). The AXP2101 register facts come from
  XPowersLib (MIT) and Waveshare's Apache-2.0 board example.
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
dissector's output (one Lua 5.4 compatibility fix applied locally). The
phone app's decoder tests (`mobile/test/odid_*_test.dart`) read the same
captures.

`tests/vectors/traffic/` (the shared traffic-rule cases) are this project's
own. `tests/vectors/net/` and `app/Tests/OrecchinoTests/Fixtures/` hold
trimmed answers recorded from the FAA TFR WFS (US-government data, public
domain) and from adsb.lol, whose data is published under the
[ODbL 1.0](https://opendatacommons.org/licenses/odbl/1-0/) (© adsb.lol
contributors); they are used only as test input.

## Data

- **UAS make/model table** (`tools/uas_models.json`, generated into
  `firmware/common/uas_models.h` and `app/Sources/Orecchino/UasModels.swift`):
  the DJI serial-prefix to model entries come from
  [Light RID Scanner](https://github.com/luyii-code-1/Light_RID_Scanner)'s
  `rid_model.json` (GPL-3.0, compatible with this project), with the names
  translated to English. The manufacturer codes are this project's own.
- **Map tiles are not distributed in this repo.** `tools/fetch_tiles.py`,
  the Mac app's "Send Map to Receiver" and the T5's own Wi-Fi sync download
  Esri World Dark Gray Canvas base tiles (JPEG, no key) for personal/offline
  use of the planned area: attribution "Esri, HERE, Garmin, © OpenStreetMap
  contributors" (map data ODbL), subject to Esri's terms of use (free
  basemap use; an ArcGIS account may be required for production use). Each
  names the app in its User-Agent and stays at or under 4 tiles a second.
  Older tiles from CARTO `dark_all` (© OpenStreetMap contributors, © CARTO)
  may remain on a SenseCAP; CARTO now requires an API key. For
  redistribution or heavier use, generate tiles from OSM data or self-host
  (e.g. Protomaps/OpenMapTiles) instead. The host test's tile fixture
  (`tests/vectors/tiles/`) is synthetic, not map imagery.
- **Phone app map tiles** (`mobile/`, the Live screen's Map mode): fetched
  live from Esri's World Dark Gray Canvas base and reference layers
  (server.arcgisonline.com, no key), cached on the phone (at most 50 MB),
  never prefetched or redistributed; the attribution "Esri, HERE, Garmin,
  © OpenStreetMap contributors" (map data ODbL) is always on screen, and
  use is subject to Esri's terms of use as above. The person can set their
  own tile template and attribution instead (Detectors > Settings > Map
  tiles).
- **FAA TFR polygons** (macOS app, and the T5 over Wi-Fi) are fetched
  live from tfr.faa.gov (US-government data, public domain).
- **ADS-B aircraft** (macOS app, phone app, and the T5 over Wi-Fi) are
  fetched live from [adsb.lol](https://www.adsb.lol/docs/open-data/api/),
  a community feed whose data is licensed ODbL 1.0; aircraft are held in
  memory only while current (at most 60 s) and never redistributed. The
  Mac app names adsb.lol in a tooltip, the phone app in its Detectors
  view, and the T5 on its SYSTEM screen beside the ADS-B radius ("ADS-B
  data: adsb.lol (ODbL)", and on the side view's panel when there is
  room). The T5 also fetches Esri tiles for
  its own area (at most 4 a second, a 3 km circle by default, zooms 12-15)
  on the same terms as `tools/fetch_tiles.py` above.

## Specifications

The ASTM F3411 / Open Drone ID message layouts were implemented from the
public specification; no decoder code was copied from other projects.

The GB 46750-2025 packet layout in `firmware/common/gb46750_decode.h`
(data type, version, length, item bitmap, fixed item lengths and units)
was taken from the Light RID Scanner project's Python parser (GPL-3.0) and
reimplemented here in C, and ported from that C to Dart for the phone's
own receiver (`mobile/lib/core/odid/gb46750.dart`); the two test vectors in
`tests/odid_test.c` and `tests/core_test.cpp` (a DJI Matrice 400's ASTM v1
beacon and a DJI Mini 5 Pro's GB 46750 packet), mirrored in
`mobile/test/odid_decoder_test.dart` and `odid_rid_line_test.dart`, are
that project's captures. The 5-degree no-fix
band around 0,0 and the "RID-" SSID convention are observations from the
same project.
