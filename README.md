# Orecchino

Orecchino is a small ear for drone Remote ID. Most drones must broadcast
their identity and position using a standard called Remote ID (ASTM F3411 /
Open Drone ID). Orecchino listens for those broadcasts and puts them on a
map.

The project is one receiver core, five boards, and a Mac app:

- A USB receiver stick, built on the Seeed XIAO ESP32-C3.
- A touch-screen map console, built on the Seeed SenseCAP Indicator, that
  works on its own with no computer attached.
- A handheld with a knob and an LED ring, built on the LilyGO T-Embed CC1101.
- A sunlight-readable e-paper board, built on the LilyGO T5 E-Paper S3 Pro.
- A pocket AMOLED touch screen, built on the Waveshare ESP32-C6-Touch-AMOLED-1.8.
- A native macOS app that shows every drone and its operator on a live map.

Every board runs the same radio core and speaks the same JSON over USB, so
the Mac app treats them all alike. What differs is the screen — and each
screen is laid out for what that board is good at, not scaled from another.

```
 [drone]  ~~WiFi beacon / NAN / BLE~~>  [receiver]  --USB JSON-->  [Orecchino.app]
```

Orecchino only listens. It never transmits on any radio.

![Device console and app UI](docs/screens.png)
*Simulated data, rendered with the real UI code and map tiles.*

## How it works

Drones broadcast Remote ID over Wi-Fi and Bluetooth. The receiver listens
on every path at once: Wi-Fi beacons, Wi-Fi Aware (NAN), and Bluetooth LE —
including the long-range mode added in Bluetooth 5. Each decoded broadcast
is sent over USB as one line of JSON. The Mac app reads that stream and
draws it.

The radio core lives in one place, `firmware/common/rx_core.h`: Wi-Fi and
BLE capture, the ASTM F3411 decoder (plus GB 46750-2025, China's 2025
Remote ID standard, which DJI's 2026 firmware sends in the same Wi-Fi
element), Authentication signature checks, the on-device track table, and
the serial protocol. A board sketch names
itself, includes the core, and calls `rx_begin()` / `rx_tick()`. Anything
the board adds — a screen, a buzzer, a spectrum view, a tile store — hangs
off four small hook functions, so a new board is a display driver and a
layout, nothing more. The headless USB stick is twenty lines.

## USB receiver — `firmware/orecchino_fw`

Install the one library it needs, then build and flash:

```bash
arduino-cli lib install "NimBLE-Arduino"
```

```bash
arduino-cli compile -b esp32:esp32:XIAO_ESP32C3:PartitionScheme=huge_app firmware/orecchino_fw
arduino-cli upload  -b esp32:esp32:XIAO_ESP32C3:PartitionScheme=huge_app -p /dev/cu.usbmodemXXXX firmware/orecchino_fw
```

## Touch console — `firmware/orecchino_sensecap`

The SenseCAP Indicator (ESP32-S3 with a 4-inch, 480×480 touch screen) runs
the same radio core as the USB stick, plus a full drone console. It shows
contacts on an offline dark map. Drag to pan, pinch to zoom, and tap a
drone for its details. The side button switches between map and list views.
If a drone enters an active flight restriction, the console beeps and
flags it.

There is also a hidden extra: hold the side button for ten seconds to open
a live spectrum analyzer. It shows 2.4 GHz activity by Wi-Fi channel and
uses the LoRa radio to sweep 850–930 MHz. Tap the lower chart to zoom in;
the display re-scales itself as the signal picture changes.

Install the libraries, then build and flash with one script:

```bash
arduino-cli lib install "GFX Library for Arduino" PCA95x5 PNGdec
```

```bash
tools/flash_indicator.sh /dev/cu.usbserial-XXXX
```

> **Note**: If compiling by hand or in the Arduino IDE instead of using the helper script, select **Partition Scheme: Custom** (`PartitionScheme=custom`) and include `--libraries firmware/libraries` so the sketch's custom partition table (2 MB app, 5.8 MB LittleFS map tiles) is used.

Two things to know when flashing:

- The Indicator's USB-C port is a CH340 serial chip. Use the `usbserial`
  port, not the `usbmodem` one. If auto-reset fails, hold the green top
  button while plugging in USB.
- Flashing replaces Meshtastic on LoRa models. The Meshtastic web flasher
  can restore it.

The Mac app keeps the console's offline map tiles up to date over USB on
its own (the tile store is shared code, `firmware/common/tile_store.h`, so
the e-paper board gets the same sync). To load tiles by hand instead:

```bash
python3 tools/fetch_tiles.py            # downloads into firmware/orecchino_sensecap/data
tools/pack_fs.sh /dev/cu.usbserial-XXXX # writes them to the device
```

Map data © OpenStreetMap contributors; tiles © CARTO.

## Handheld — `firmware/orecchino_tembed`

The LilyGO T-Embed CC1101 is a battery handheld: a 1.9-inch strip screen,
a rotary encoder, a side button, an 8-LED ring, and a CC1101 sub-GHz
radio. Its console is built around the knob. The left of the strip is the
contact list; the right is the selected contact's live numbers — signal,
height, speed, and when the Mac app has pushed your position, range and
bearing. Turn the knob to walk the list, click it for a full-screen
contact with big range and bearing digits (the handheld's job is to walk
toward the drone), click again to return.

The handheld does two jobs, chosen from a boot menu you reach by holding
the knob for a second; the choice is saved and survives a power cycle.
**Receiver** is the default. **Test beacon** turns the handheld into the
Remote ID transmitter described under "Test beacon" below, with the ten
transmit variants shown as a list on the strip — turn the knob to a variant
and click to switch it on or off, so you can radiate exactly one air
interface or all of them, with a master transmit toggle and an emergency
flag at the top. Switching modes reboots into the other one, because the
two use the radios differently.

In receiver mode the LED ring is the peripheral-vision channel: dark when the sky is quiet,
a slow amber breath while a contact is live, a hard red pulse for an
emergency, a flight-restriction incursion, or a forged identity. How many
LEDs light follows the strongest contact's signal, so the ring reads as a
signal meter from across the room.

The backlight dims to 25% after two minutes without input and wakes on any touch of
the knob or key — never while a danger alert is live. The side button is
**Back** from anywhere — detail, menu, beacon list, spectrum — and brightness
is a menu item; hold the side button for a spectrum view that
shows 2.4 GHz activity by Wi-Fi channel and uses the CC1101 to sweep
300–928 MHz across its three tuning ranges, with a knob-driven cursor
readout. Battery percentage comes from the board's fuel gauge, which the
firmware checks against the board's 1300 mAh cell at every boot, as on the
e-paper board below.

```bash
arduino-cli lib install "GFX Library for Arduino"
```

```bash
tools/flash_tembed.sh /dev/cu.usbmodemXXXX
```

> **Note**: If compiling by hand or in the Arduino IDE instead of using the helper script, select **Partition Scheme: Custom** (`PartitionScheme=custom`) and include `--libraries firmware/libraries` so the 3 MB app partition is used.

## E-paper board — `firmware/orecchino_t5epd`

The LilyGO T5 E-Paper S3 Pro has a 4.7-inch, 960×540 e-paper panel you
can read in full sun, plus an SX1262 LoRa radio. Its console is a tactical
board: a contact table on the left — ranked danger, then active, then
history, in order of arrival within each group so a busy sky never
reshuffles under your finger — and on the right a range-ring plot centred
on you, rings scaling to the farthest contact, each aircraft drawn with its
heading. Long IDs are shortened from the front (`1581F20..9A03`) so the
tail that tells a fleet apart survives, and plot labels are placed only
where they fit, the selected aircraft's and any alert's first. A loud row
says why in words — `EMERGENCY REPORTED`, `ID SIG INVALID`, `TFR MATCH` —
never one word for all three. Without a pushed operator position the plot
becomes a selected-contact card instead. The header turns solid black as
the alert bar.

It also carries an offline map — the same tiles the SenseCAP uses, pushed
by the Mac app's "Sync Map Tiles" button over USB. There is no second tile
set: the device re-tones CARTO's dark style into a printed street map for
daylight. Land becomes paper, streets and road edges dark lines, buildings a
faint tint, water light grey and labels black, using the greys the panel
shows distinctly. The map frames you and every
live contact at the deepest zoom that fits, draws each aircraft with its
heading and a halo so it reads over street ink, and shows a scale bar.

The board self-locates. Its GPS feeds the operator position directly, so
the range rings and the map frame around you in the field with nothing
attached; the header shows the satellite count (`GPS 9`), `GPS --` while
it searches, `APP POS` when the Mac app supplied the position instead, or
`NO POS`.

Battery percentage comes from the board's fuel gauge (a TI BQ27220), which
has to be told the cell it is measuring. Unconfigured, it counts against
TI's generic 3000 mAh profile, twice this board's cell, and its percentage
wanders far from the real charge. At every boot the firmware compares the
gauge with the 1500 mAh cell profile LilyGO publishes for this board and
rewrites it only when they differ, which costs a few seconds once. The
settings screen shows the capacity the percentage is counted against.

It has touch. The header has TABLE and MAP tabs. On the table, tap a row to
select it, then DETAILS (or a second tap) for its details; tap an aircraft
on the plot to select it, or an empty spot on the plot to open the map.
With more than eight contacts, a PAGE button in the footer turns the pages.
On the map, tap a marker to select it (a banner shows its vitals, with
DETAILS and X buttons), tap anywhere else to re-centre there, drag to pan,
and use the + / − boxes to zoom; the view stays where you put it until you
tap the reticle or the `MANUAL VIEW | TAP TO FIT ALL` button (or two
minutes pass), then it frames you and every live contact again. The footer
always says what a tap does on the current board. The selection follows the
aircraft, not the row: a packet from another drone can reorder the table
without changing what you have selected. E-paper is slow, so gestures are
whole taps and drag-releases rather than live tracking.

E-paper is slow and ghosts, so the board only redraws when its content
actually changes: fast partial updates for routine table and map changes,
a clean full refresh every ten updates, on any alert change, when you
switch views, and at least every five minutes. The BOOT button steps
through contacts on the table, then over to the map, then back; hold it
for two seconds to power the board off (the key labelled IO48 does the
same after a short hold; in test beacon mode the BOOT hold returns to
receiver mode instead). The PWR key only switches the board on: it is not
wired to the processor, so the firmware cannot read it. The SYSTEM button
in the footer opens a settings screen: backlight control first, then the mode switch and power-off (each behind a
confirmation), hardware readouts, and the engineering controls last (panel
voltage (VCOM) trim and a greyscale test strip). The details card
qualifies its airspace line by what TFR data the app has actually pushed —
it never calls the sky clear on an empty table — labels height by the
reference the aircraft transmitted (AGL or above take-off), names the
model for DJI serials, shows the beacon SSID, and says when that SSID
names a different serial than the broadcast ID.

The touch controller differs between production batches — a Goodix GT911
on some, a GT6972P on others — and the firmware probes for both at boot.

The panel driver is [epdiy](https://github.com/vroland/epdiy), vendored
under `firmware/libraries/epdiy` (the board is an epdiy v7 layout).

```bash
tools/flash_t5epd.sh                # finds the port itself; pass one to override
tools/flash_t5epd.sh --clock-only   # set the board's clock without reflashing
```

The board has no network, and its automatic sunset backlight and UTC
readout run off its clock, so the script finishes by setting that clock
from this computer's. The board answers with the time its clock chip reads
back after the write — the time that survives a reset — and the script
checks that, then tells you the result, or exactly what went wrong. The
Mac app also sets the clock whenever it connects, and again with each
airspace-data refresh.

> **Note**: If compiling by hand or in the Arduino IDE instead of using the helper script, select **Partition Scheme: Custom** (`PartitionScheme=custom`) and include `--libraries firmware/libraries` to include the vendored `epdiy` library and use the 3 MB app partition.

## Pocket AMOLED — `firmware/orecchino_amoled`

The Waveshare ESP32-C6-Touch-AMOLED-1.8 is the small one: a 1.8-inch,
368×448 AMOLED touch screen on an ESP32-C6. The same radio core runs on
the C6's single RISC-V core. The console is a card stack — up to four
contacts on screen, drag to scroll, tap a card for the full-screen contact
with big range and bearing digits, tap again to return. AMOLED pixels only
cost power when lit, so the design is black-on-black with a breathing ring
while scanning, and the panel dims after thirty seconds idle (a live danger
keeps it bright). Hold the button for a 2.4 GHz spectrum view with a
waterfall; the C6 has no sub-GHz radio.

Two revisions of this board ship under one name — an older one with a
SH8601 panel controller and FT3168 touch, a newer one with a CO5300 and
CST816 touch. The firmware tells them apart at boot by which touch chip
answers and drives the panel accordingly. Drawing goes through an 8-bit
canvas rather than straight to the panel: these QSPI AMOLED controllers drop
writes at odd column addresses, which silently erases text drawn pixel by
pixel. The glass is a rounded rectangle, so nothing is placed in the corners.
Battery percentage comes from the fuel gauge in the board's AXP2101 power
chip, which the firmware switches on at boot; with no battery fitted the
readout is hidden rather than showing a meaningless number.

```bash
arduino-cli lib install "GFX Library for Arduino"
```

```bash
tools/flash_amoled.sh /dev/cu.usbmodemXXXX
```

> **Note**: If compiling by hand or in the Arduino IDE instead of using the helper script, select **Partition Scheme: Custom** (`PartitionScheme=custom`) and include `--libraries firmware/libraries` so the 3 MB app partition is used.

## macOS app — `app/`

SwiftUI and MapKit, with no outside dependencies. It builds with the
Command Line Tools alone (macOS 14 or newer):

```bash
app/Scripts/make_app.sh     # produces app/build/Orecchino.app
open app/build/Orecchino.app
```

What it does:

- Live dark map with color-coded drones, heading arrows, flight trails,
  and operator positions. Labels hide where they would cover another
  label or marker; the selected and any alerting aircraft are always
  labelled and drawn on top
- Active FAA flight restrictions (TFRs) drawn on the map, refreshed every
  15 minutes and pushed to the receiver on every refresh
- A sidebar list and a detail card for each drone; missing data is shown
  as blank, never as fake zeros. An emergency or a failed ID signature is
  a complete label that never truncates (`EMERGENCY REPORTED`,
  `ID SIGNATURE INVALID`) and a distinct marker shape on the map, never
  colour alone
- The detail card leads with status, last heard, range from this Mac,
  height with the reference the aircraft transmitted (AGL or above
  take-off), speed and the aircraft-to-operator distance; radio details
  (RSSI, transports, MACs, evidence, counters) sit behind a collapsed
  "Technical details" section. The card is height-bounded and scrolls,
  and map fitting keeps aircraft out from under it
- One receiver-health state drives the toolbar badge, the status strip and
  the empty sidebar (no receiver / waiting for data / receiving / no
  heartbeat); with no receiver the sidebar offers a port picker and
  "Retry auto-detect". Tracks go stale after 60 s on every surface, the
  same minute the receivers use
- Names the model for DJI serial numbers (`DJI Mini 4 Pro`) from a table
  shared with the firmware, and flags a beacon whose SSID names a
  different serial than its Basic ID
- Flags a drone whose claimed operator position is more than 15 km away,
  and restarts a trail rather than drawing a jump no aircraft could make
- Finds the receiver's USB port by itself and reconnects after unplugs,
  and sets the receiver's clock whenever it connects and with each
  airspace-data refresh (the boards have no network of their own)
- A demo mode with two simulated drones, so the UI can be tried with no
  hardware: a persistent SIMULATION ACTIVE banner, a SIMULATED badge on
  every simulated row, marker and card, and "(N simulated)" in the count

## Data format

Each decoded broadcast is one JSON object per line:

```json
{"type":"rid","src":"ble","mac":"AA:BB:CC:DD:EE:FF","rssi":-61,"phy":"coded",
 "proto":2,
 "basic_id":[{"id_type":1,"ua_type":2,"uas_id":"1581F..."}],
 "loc":{"status":2,"lat":37.1234567,"lon":-122.1234567,"alt_geo":82.0,
        "alt_baro":80.5,"height":60.0,"height_ref":0,"speed":8.0,
        "vspeed":0.5,"dir":123,"ts":1801.2},
 "self_id":{"desc_type":0,"desc":"Survey"},
 "system":{"op_lat":37.12,"op_lon":-122.12,"op_alt":12.0,"op_loc_type":1,
           "area_count":1,"ts":238912345},
 "op_id":{"id_type":0,"id":"FIN87astrdge12k8"}}
```

Any device that speaks this format over a serial port can feed the app —
an SDR pipeline works just as well as the ESP32 receivers.

Every line says which wire format spoke: `"proto"` is the ASTM F3411
protocol version from the message header, and `"fmt":"gb46750"` replaces
it for a GB 46750-2025 packet, which the receivers decode into the same
fields (its registration mark becomes a second, CAA-type `basic_id`). A
Wi-Fi beacon's SSID rides along as `"ssid"`; when it follows DJI's
`RID-<serial>` convention, `"ssid_id_match"` says whether that serial
agrees with the Basic ID message, so a broadcast at odds with itself is
visible. Positions in the no-fix band DJI encoders emit around 0,0 are
dropped before they reach the track.

When a drone sends signed Authentication messages, the receiver adds an
`"auth"` field with a `state` of `id_valid`, `invalid`, `partial`,
`unknown_key`, or `none`. Read `id_valid` narrowly: it means the drone's
**ID** was signed by a key the receiver trusts. The position is not
signed, and old signatures are not rejected, so a valid state is never a
reason to trust where a drone claims to be. Pages are collected per
aircraft, so a signature spread over several single-message advertisements
(BLE4 legacy) still verifies; from then on every line for that aircraft
carries the `auth` field with the verdict of the last complete set.

## Test beacon — `firmware/orecchino_tx`

The transmitter is a shared core (`firmware/common/tx_core.h`): the XIAO
sketch here is the headless USB version, and the T-Embed runs the very same
beacon with an on-screen variant picker (see the handheld section).

A **test transmitter** for bench-checking a receiver without waiting for a
real drone overhead. Flashed to a spare XIAO ESP32-C3, it flies a synthetic
aircraft in a circle around a configurable home point and broadcasts it on
both paths a receiver decodes — WiFi beacon vendor IE on channel 6, and BLE
service data `0xFFFA` (BT5 extended when available, else BT4 legacy rotating
one message per advertisement).

**Each transmit path flies its own aircraft with its own identity**, so a
receiver's contact list doubles as a path checklist — a missing contact
names the path that isn't getting through:

| UAS ID | Path | Height |
| --- | --- | --- |
| `ORECCHINO-TEST-WIFI` | WiFi beacon, vendor IE, channel 6 | 60 m |
| `ORECCHINO-TEST-NAN` | WiFi NAN service discovery frame | 75 m |
| `ORECCHINO-TEST-BLE5` | BLE 5 extended advertising, 1M PHY | 90 m |
| `ORECCHINO-TEST-BLELR` | BLE 5 extended, coded PHY (long range) | 105 m |
| `ORECCHINO-TEST-BLE4` | BLE 4 legacy, one message per advertisement | 120 m |

The five orbit centres sit on a 200 m (~⅛ mile) ring around the home point
at 72° intervals, each at its own altitude, so the markers are clearly
separated on a map. Self ID and operator ID carry the path name too, and
each aircraft transmits from its own MAC / BLE address.

The ESP32-C3's BLE controller only grants two advertising sets, so the
three BLE flavours time-share them (1M keeps one set; coded and legacy
alternate on the other). Per-path transmit counters in the serial status
make a dead path obvious, and failures are reported rather than swallowed.

> This is test equipment, **not a compliant Remote ID transmitter**. The IDs
> are obviously synthetic by design so a stray capture can't be mistaken for
> a real aircraft. Mind local rules on what you transmit.

```bash
arduino-cli compile --jobs 2 -b esp32:esp32:XIAO_ESP32C3:PartitionScheme=huge_app firmware/orecchino_tx
arduino-cli upload  -b esp32:esp32:XIAO_ESP32C3:PartitionScheme=huge_app -p /dev/cu.usbmodemXXXX firmware/orecchino_tx
```

Serial control (115200, one command per line): `s` status, `go`/`stop`,
`e` toggle emergency status (exercises the alert path and the SenseCAP's
TFR/emergency banner), `h <lat> <lon>` move the home point, `r <metres>`
orbit radius. Status lines report per-path transmit counters and live
position. The encoder lives in `firmware/common/odid_build.h` and is
round-trip tested against the decoder in the suite below.

## Testing

```bash
tests/run_tests.sh
```

The T5 flash script's clock step is tested against a fake board on a
pseudo-terminal (`tests/flash_clock_test.sh`): every answer the firmware
can give, a slow boot, a lost command, and `Ctrl-C`, `Ctrl-\`, TERM and
HUP mid-step, none of which may leave a reader on the port.

The fuel-gauge code runs against simulated chips (`tests/gauge_test.cpp`).
The simulated BQ27220 reproduces what the T5's real one does: a reset that
lands seconds after the command, and data that reads back as junk for
seconds after the gauge re-initialises. The tests pin the exact bytes of a
data-memory write. They also check that a gauge already holding the
profile is never written, and that no failure leaves it unsealed or stuck
in configuration mode, where it stops counting.

Every receiver shares one Remote ID decoder (`firmware/common/odid_decode.h`,
with `gb46750_decode.h` for GB 46750-2025) and one radio core
(`rx_core.h`, `tracker.h`); the transmitters share `tx_core.h`. The
decoder is tested on the host against real over-the-air captures from the
official OpenDroneID reference tools, a real DJI beacon, and a real GB
46750-2025 packet. The make/model tables in `firmware/common/uas_models.h`
and the app are generated from `tools/uas_models.json` by
`tools/gen_uas_models.py`, and the suite fails if they drift. The cores are tested
on the host too, against the shims in `tests/host_shim`: one aircraft staying
one contact across its Wi-Fi and BLE addresses, Authentication pages
assembled across frames, the beacon's format variants reaching the encoder,
and the transmitter's off switches actually silencing its BLE advertising
sets. The T5 board's drawing code is rendered on the host too, with the
real font bitmaps, against a stress fixture of twelve contacts sharing a
serial prefix: every scene must come out with no two text runs colliding,
and the selection must survive a re-sort, an alert and an expiry (the
scenes are written to `/tmp/t5_*.pgm` for eyes). That check needs the
Adafruit GFX library's `Fonts/` in `~/Documents/Arduino/libraries` and is
skipped without it. App tests cover the serial format, checksums, tile
math, identity conflicts between tracks, and tile-sync state.

## License

GPL-3.0-or-later — see [LICENSE](LICENSE). Third-party components are
listed in [THIRD_PARTY.md](THIRD_PARTY.md); all are GPL-compatible. Map
tiles are fetched by the user and are not part of this repository.
