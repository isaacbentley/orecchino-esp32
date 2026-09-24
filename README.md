# Orecchino

Orecchino is a small ear for drone Remote ID. Most drones must broadcast
their identity and position using a standard called Remote ID (ASTM F3411 /
Open Drone ID). Orecchino listens for those broadcasts and puts them on a
map.

The project is one receiver core, five boards, a Mac app and a phone app:

- A USB receiver stick, built on the Seeed XIAO ESP32-C3.
- A touch-screen map console, built on the Seeed SenseCAP Indicator, that
  works on its own with no computer attached.
- A handheld with a knob and an LED ring, built on the LilyGO T-Embed CC1101.
- A sunlight-readable e-paper board, built on the LilyGO T5 E-Paper S3 Pro,
  which can also join Wi-Fi for its own clock, flight restrictions, map
  tiles and ADS-B traffic.
- A pocket AMOLED touch screen, built on the Waveshare ESP32-C6-Touch-AMOLED-1.8.
- A native macOS app that shows every drone and its operator on a live map,
  with ADS-B traffic alerts.
- An iOS and Android app (`mobile/`) that pairs with any receiver over
  Bluetooth LE.

Every board runs the same radio core and speaks the same JSON over USB and
over Bluetooth LE, so the apps treat them all alike. What differs is the
screen — and each screen is laid out for what that board is good at, not
scaled from another.

```
 [drone]  ~~WiFi beacon / NAN / BLE~~>  [receiver]  --USB JSON-->  [Orecchino.app]
                                                    --BLE JSON-->  [phone app]
```

The receivers only listen for drones; they never transmit Remote ID. What
they do send is their own link: a Bluetooth LE advertisement every half
second so the phone app can find them (and the connection once a phone
pairs), and, on the T5, a Wi-Fi connection when you set one up. The test
beacon (below) is the one thing here that transmits Remote ID, and only on
purpose.

![Device console and app UI](docs/screens.png)
*Simulated data, rendered with the real UI code and map tiles.*

## How it works

Drones broadcast Remote ID over Wi-Fi and Bluetooth. The receiver listens
on every path at once: Wi-Fi beacons, Wi-Fi Aware (NAN), and Bluetooth LE —
including the long-range mode added in Bluetooth 5. Each decoded broadcast
is sent over USB, and to a paired phone that asked for the live feed, as
one line of JSON. The apps read that stream and draw it.

The radio core lives in one place, `firmware/common/rx_core.h`: Wi-Fi and
BLE capture, the ASTM F3411 decoder (plus GB 46750-2025, China's 2025
Remote ID standard, which DJI's 2026 firmware sends in the same Wi-Fi
element), Authentication signature checks, the on-device track table, and
the JSON line protocol over USB and Bluetooth LE (`host_link.h`,
`ble_link.h`). A board sketch names
itself, includes the core, and calls `rx_begin()` / `rx_tick()`. Anything
the board adds — a screen, a buzzer, a spectrum view, a tile store — hangs
off five small hook functions, so a new board is a display driver and a
layout, nothing more. The headless USB stick is twenty lines.

Nothing on the detection path waits for the board's screen. The radio
callbacks queue matched frames; a decode task wakes the moment one lands,
decodes it, updates the contact and writes its JSON line; a timer hops the
Wi-Fi channel. The sketch's loop only reads commands from the app, ages
contacts out, saves the match log, and copies the track table for the
screen, so an e-paper refresh that takes a second no longer delays or drops
a detection.

Every receiver also keeps a **match log**: one record for each drone it
has lost track of (ID, addresses, how it was heard, first and last heard,
last position, highest altitude, strongest signal, whether it was ever in
a flight restriction or reported an emergency, and its signature verdict).
The last 48 records are kept in flash and survive power cycles, so a
receiver left out on its own can be read back later from the Mac or phone
app. Every record gets a sequence number that never changes, so an app
reads only what is new since its last visit. Flash wears, so the log is
written at most once every 10 minutes, and at once when the T5 is powered
off from its menu or the T5 or T-Embed switches to test beacon mode; a
power cut, crash or unplug can lose the contacts that ended in the last 10
minutes. The observer's last position is kept in flash too (saved on a
first fix and after a move of more than 500 m, at most every 10 minutes),
so a restarted board still has a centre for its range rings and TFR checks
before a GPS fix or an app arrives.

### Bluetooth LE link

Every receiver (not the test beacon) also serves the JSON line protocol
over Bluetooth LE, as `Orecchino-XXXX` (the end of its Bluetooth address),
using the Nordic UART Service layout so generic tools such as nRF Connect
can talk to it: RX `6E400002-…` takes command lines, TX `6E400003-…`
notifies output lines in MTU-sized slices. A second, readable service
(`0A1B0001-5E1D-4F0E-9C7B-4F52454343A1`, characteristic `0A1B0002-…`)
answers before pairing with `{"fw":"orecchino","ver":…,"board":…,"caps":[…],"proto":1}`,
so a phone can tell an Orecchino from any other NUS device. `caps` is what
that board handles: `log`, `log_since` and `tfr` on every receiver, plus
`tiles` on the SenseCAP and `tiles`, `wifi` and `traffic` on the T5.

One phone at a time. Everything needs an encrypted link: pairing uses a
passkey, and the passkey is the **fixed, published 123456** on every
Orecchino. That is deliberate — it keeps passers-by out, not a determined
attacker; the T5 shows the code while pairing and says so on screen. A
peer that has not paired within 10 seconds is dropped, so it cannot sit on
the only connection. The live feed (`rid` and `hb` lines) goes to the phone
only after it sends `{"cmd":"feed","on":true}`; replies go only to the
transport a command came in on. On the SenseCAP and T5, `fs_*` tile
commands work over BLE as over USB; the T5's Wi-Fi setup commands need the
BLE link, or USB while the T5's own setup screen is open (see "Wi-Fi"
below).

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
height, speed, and when an app (Mac or phone) has pushed your position, a small
north-up compass with a needle toward the aircraft, its range and bearing,
and whether it is **closing** on you or opening (worked out from its
range over successive fixes). A contact with no ID yet is listed by the
end of its address. Turn the knob to walk the list, click it for a
full-screen contact with big range and bearing digits, the compass and the
closing speed (the handheld's job is to walk toward the drone), click
again to return. Only the parts of the screen that changed are sent to
the panel, so a clock tick costs a tenth of a full frame.

The handheld does two jobs, chosen from a boot menu you reach by holding
the knob for a second; the choice is saved and survives a power cycle.
**Receiver** is the default. **Test beacon** turns the handheld into the
Remote ID transmitter described under "Test beacon" below, with the ten
transmit variants listed by name (WIFI, BLE5, AUTHBAD, ...) with their
carrier — turn the knob to a variant and click to switch it on or off, so you can radiate exactly one air
interface or all of them, with a master transmit toggle and an emergency
flag at the top. Switching modes reboots into the other one, because the
two use the radios differently.

In receiver mode the LED ring is the peripheral-vision channel: dark when the sky is quiet,
a slow amber breath while a contact is live, a hard red pulse for an
emergency, a flight-restriction incursion, or a forged identity. How many
LEDs light follows the strongest contact's signal, so the ring reads as a
signal meter from across the room.

The backlight dims to 25% after two minutes without input and wakes on any touch of
the knob or key — never while a danger alert is live. After sunset where
an app last placed you it runs 30% dimmer (the apps set the clock
this needs whenever they connect). The side button is
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
becomes a selected-contact card instead; with one, the card's range rate
says whether the aircraft is closing on you or opening. The header turns
solid black as the alert bar. In test beacon mode each card is titled by
its variant (WIFI, NAN, BLE5, ... AUTHBAD).

Left untouched for five minutes, the board switches to **glance mode**, a
screen meant to be read across a room: how many drones are in range in
numerals a fifth of the screen tall, the nearest one's range, bearing and
height, and a black band that appears only when there is an alert, saying
which (`1 EMERGENCY | 1 IN A TFR`). E-paper holds it without power, and it
refreshes only when what it says changes. Any touch or button brings back
the board exactly as it was, without acting on that touch.

It also carries an offline map — the same tiles the SenseCAP uses, pushed
by the Mac app's "Sync Map Tiles" button over USB or fetched by the board
itself over Wi-Fi (below). There is no second tile
set: the device re-tones CARTO's dark style into a printed street map for
daylight. Land becomes paper, streets and road edges dark lines, buildings a
faint tint, water light grey and labels black, using the greys the panel
shows distinctly. The map frames you and every
live contact at the deepest zoom that fits, draws each aircraft with its
heading and a halo so it reads over street ink, and shows a scale bar.

The board self-locates. Its GPS feeds the operator position directly, so
the range rings and the map frame around you in the field with nothing
attached; the header shows the satellite count (`GPS 9`), `GPS --` while
it searches, `APP POS` when the position came from the Mac or phone app
instead (or is the last one saved before a restart), or `NO POS`.

Battery percentage comes from the board's fuel gauge (a TI BQ27220), which
has to be told the cell it is measuring. Unconfigured, it counts against
TI's generic 3000 mAh profile, twice this board's cell, and its percentage
wanders far from the real charge. At every boot the firmware compares the
gauge with the 1500 mAh cell profile LilyGO publishes for this board and
rewrites it only when they differ, which costs a few seconds once. The
settings screen shows the capacity the percentage is counted against.

It has touch. The header has TABLE, MAP and SIDE tabs. On the table, tap a row to
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

The SIDE tab plots height against range: the plan views say where, this
says how high. A dashed line marks the 120 m (400 ft) ceiling of US Part
107 and the EU open category, the band above it is dotted, and aircraft
over it are drawn as squares and ranked by height beside the plot. Heights
are what each aircraft broadcasts, above take-off or above ground as it
says, and the panel says so; contacts with no position or no height are
counted rather than guessed at. Tap a mark to select it, again for its
details. The round home button steps table, map, side.

E-paper is slow and ghosts, so the board only redraws when its content
actually changes: fast partial updates for routine table and map changes,
a clean full refresh every ten updates, on any alert change, when you
switch views, and at least every five minutes. The BOOT button steps
through contacts on the table, then over to the map, the side view, and
back; hold it
for two seconds to power the board off (the key labelled IO48 does the
same after a short hold; in test beacon mode the BOOT hold returns to
receiver mode instead). The PWR key only switches the board on: it is not
wired to the processor, so the firmware cannot read it. The SYSTEM button
in the footer opens a settings screen: backlight control first, then the mode switch and power-off (each behind a
confirmation), the Wi-Fi section (below), hardware readouts, and the
engineering controls last (panel voltage (VCOM) trim and a greyscale test
strip). The details card
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

The board's automatic sunset backlight and UTC readout run off its clock,
and until it has synced over Wi-Fi (below) nothing else sets it, so the
script finishes by setting that clock from this computer's. The board
answers with the time its clock chip reads back after the write — the time
that survives a reset — and the script checks that, then tells you the
result, or exactly what went wrong. The Mac and phone apps also set the
clock whenever they connect, and the Mac again with each airspace-data
refresh. Like every flash script here, it refuses to guess when more than
one board is plugged in (name the port), and asks Orecchino.app to quit
before flashing, forcing it only if it has not gone within 5 seconds.

### Wi-Fi (T5 only)

The T5 can join a Wi-Fi network to fetch, on its own: the time (SNTP), the
FAA flight restrictions within 200 km, ADS-B aircraft within 17 NM
(31.5 km) from adsb.lol, and CARTO map tiles at zooms 11-15 within 8 km —
all around its own position, so it needs a GPS fix, an app's position or a
saved one first. Everything is HTTPS, checked against the root certificate
bundle built into the ESP32 core.

The board has one 2.4 GHz radio, and joining a network pins it to the
access point's channel. The WI-FI section of SYSTEM therefore offers three
modes, and says in words what it is doing (`CONNECTED to Home (ch 6)`,
`FAILED: wrong password, retry in 2 min`, ...):

- **SYNC** (the default): a short sync window every 15 minutes (5-60,
  settable from the phone app) and on **SYNC NOW**. Channel hopping holds
  for the few seconds of the window; Remote ID keeps being decoded on the
  current channel.
- **STAY**: associated all the time, ADS-B every 10 seconds, TFRs and the
  clock every 15 minutes. Remote ID over Wi-Fi is then heard on the access
  point's channel only (BLE is unaffected), and the footer says so:
  `WI-FI CH 6 ONLY`.
- **OFF**: no automatic joins.

**NETWORKS** scans (Remote ID Wi-Fi pauses for the ~2 s scan, and the
screen says so) and lists what it finds with signal bars, a lock for
secured networks and a SAVED chip; tap a saved one for CONNECT or FORGET,
a new one (or "Other network...") for a full-screen keyboard with a
SHOW/HIDE toggle for the password. A network is saved only after it has
joined; up to five are kept, **in plain text in the board's NVS**, where
anyone holding the board and a USB cable can read them out. **UPDATE MAP**
fetches every missing tile around the board's position (at most 4 a second,
stopping when LittleFS has under 1 MB free); the automatic windows add at
most 8 new tiles each, and refresh the area weekly. Failed joins and jobs
back off (1, 2, 5, 15 minutes).

The phone app can do the same over BLE (scan, join, forget, mode). Over
USB those commands are refused unless the T5's Wi-Fi setup screen has been
opened in the last 5 minutes, so a USB cable alone cannot change the
networks (a bench build can lift that with `-DNET_SERIAL_PROVISIONING=1`).
For development, copy `firmware/common/wifi_secrets.example.h` to
`firmware/common/wifi_secrets.h` (git-ignored; never commit it) to give the
board a network to use while none is saved on it.

TLS needs about 33 KB of the chip's internal RAM, which the Wi-Fi and
Bluetooth drivers and the panel also need, so every request first checks
it: under 40 KB free, or no 18 KB block, the job fails with `low memory`
in words rather than risking the radios. The numbers are reported in the
board's `net` status line.

### ADS-B traffic on the T5

Aircraft come from the board's own Wi-Fi fetch or from the Mac or phone
app (the `traffic` lines below), and are checked against the drones the
board hears by the rules in `firmware/common/traffic.h` — the same rules,
line for line, as the Mac and phone apps, tested on the same vectors:

- `TRAFFIC NEAR DRONE <id>`: a drone and an airborne aircraft within 1 km
  horizontally and 150 m vertically (or with either height unknown, said
  as `HEIGHT UNKNOWN`, never dropped).
- `TRAFFIC CONVERGING WITH <id>, <n> S`: their reported tracks come within
  500 m in the next minute.
- `LOW TRAFFIC <bearing> <km>`: an aircraft within 3 km of you and below
  1,500 ft above you.
- `HIJACK` / `RADIO FAILURE` / `EMERGENCY` squawks within 30 km.

An alert clears only after the pair has been beyond 1.3 km or 200 m for 20
seconds, so it cannot flap. Aircraft reported on the ground (taxiing,
parked) never raise LOW or CONVERGING and are not counted as traffic; one
within 1 km of a drone is still shown, as a caution
(`..., AIRCRAFT ON GROUND`), not a warning. When the newest data is over 30
seconds old no new alert is raised and the board says `TRAFFIC DATA
STALE`. These are reported positions, not predictions, and not every
aircraft broadcasts ADS-B: no screen ever says "clear" or "safe".

A new warning is the one thing that interrupts the board: a full refresh
(the black flash is the only motion e-paper has) and three pulses of the
front light, day or night. The header's headline gives the traffic words,
the header shows `ADS-B 12` (aircraft held) or `ADS-B STALE`, and the
footer `TRAFFIC 2` (airborne aircraft within 3 km). While a warning lasts
the plot panel becomes a traffic card: callsign and type, where the
aircraft is relative to the drone, its altitude, speed, climb or descent,
and the data age. On the plot and the map aircraft are outlined diamonds,
never filled, with a heading tick and a dot every 15 s along the next
minute of track (a plain small diamond when on the ground); tap one for its
card. The side view draws them on the same height axis (up to 1,500 m) with
a bracket joining each traffic pair, and glance mode's band and line carry
the traffic words and the nearest aircraft.

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
  15 minutes and pushed to the receiver on every refresh: the 16 nearest
  within 200 km of this Mac (or of the drones when the Mac has no
  position; with neither, the receiver keeps what it has), each fitted into the receivers'
  24-point limit as a polygon that encloses the real outline, never one
  that cuts inside it
- ADS-B traffic from adsb.lol within 17 NM (31.5 km) of this Mac, else of
  the drones, every 10 s (backing off on errors), under a **Traffic**
  toolbar toggle: aircraft on the map with a dashed one-minute projection,
  a separation bridge between each drone and aircraft pair, traffic alerts
  in the sidebar in the rules' words above the drones (each with **Show**
  to frame the pair), an aircraft card, a "Nearest traffic" line on each
  drone's card, and a status pill giving the feed's state and data age
  (`TRAFFIC DATA STALE`, a failed fetch and its retry, no position). The
  rules are `firmware/common/traffic.h`, ported to `TrafficRules.swift` and
  tested on the same vectors. Warnings raise a time-sensitive notification
  at most once per drone-aircraft pair every 5 minutes, and a menu bar item
  (an airplane with the count of airborne aircraft within 3 km, filled with
  a `!` while a warning is active) lists the alerts from any app. The app
  pushes the aircraft to a receiver whose capabilities include `traffic`
  (the T5) every 10 s. The source can be pointed elsewhere with
  `defaults write dev.bentley.orecchino adsbURL 'https://…/{lat}/{lon}/{radius}'`
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
  airspace-data refresh. `ORECCHINO_DEBUG=1` traces the port search to
  `~/Library/Logs/Orecchino/serial.log`
- Device > Match Log reads the receiver's match log: every drone it has
  lost track of, even while no Mac was connected, newest first, with the
  ones it still holds on top. After the first read it asks only for
  records it has not seen (`since`), and says how many rotated out of the
  receiver's ring before it could read them. It can be exported as CSV or
  cleared. Times need the receiver's clock, which the app sets on connect;
  records made before that say so instead of showing a wrong date
- A signature under the public test key (the test beacon's) reads
  `TEST KEY`, neutrally, never as a verified identity
- A demo mode with two simulated drones, so the UI can be tried with no
  hardware (and two simulated aircraft, one passing close): a persistent
  SIMULATION ACTIVE banner, a SIMULATED badge on every simulated row,
  marker and card, and "(N simulated)" in the count. Simulated aircraft
  are never pushed to a receiver

## Phone app — `mobile/`

A Flutter app for iOS and Android that pairs with any receiver over
Bluetooth LE: a 3D sky view of what the receiver hears (contacts on height
stems over a perspective radar, separation bridges to nearby aircraft), a
point-at-the-sky Find view with bearing and elevation, a scrubbable history
timeline with replay, the receiver's match log kept on the phone (synced
incrementally), the
phone's position and time pushed to the receiver, ADS-B traffic alerts with
the same rules as the boards and the Mac, and the T5's Wi-Fi setup. Build,
permissions, privacy and what is still to do are in
[`mobile/README.md`](mobile/README.md).

```bash
cd mobile && flutter test
```

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

Any device that speaks this format over a serial port can feed the Mac app —
an SDR pipeline works just as well as the ESP32 receivers.

A transmitter repeating an identical frame (a BLE advertisement is resent
many times a second) is reported at most once a second per path; the
contact on the receiver still counts every copy. Any change in the frame
is reported at once.

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
`"auth"` field with a `state` of `id_valid`, `test_key`, `invalid`,
`partial`, `unknown_key`, or `none`. Read `id_valid` narrowly: it means the drone's
**ID** was signed by a key the receiver trusts. The position is not
signed, and old signatures are not rejected, so a valid state is never a
reason to trust where a drone claims to be. Pages are collected per
aircraft, so a signature spread over several single-message advertisements
(BLE4 legacy) still verifies; from then on every line for that aircraft
carries the `auth` field with the verdict of the last complete set.
`test_key` is a signature under the public test key this repository
publishes for the test beacon (`firmware/common/odid_auth.h`): anyone can
make one, so it is its own state, shown as `TEST KEY`, never as a verified
ID. A build that wants the bench beacon to read `id_valid` (to exercise
that path of a UI) defines `ORECCHINO_TRUST_TEST_KEY`.

### Board lines

Once at boot, and a heartbeat every 2 seconds:

```json
{"type":"boot","fw":"orecchino","ver":"0.7.0","board":"lilygo-t5-epaper-s3-pro","wifi":true,
 "ble":true,"ble_ext":true,"caps":["log","log_since","tfr","tiles","wifi","traffic"],
 "display":true,"vcom":1560,"mode":"rx"}
{"type":"hb","up":123456,"wifi_frames":8812,"ble_advs":20431,"rid":312,"dropped":0,
 "ch":6,"ble":true,"ble_ext":true,"caps":[...],"ble_drop":3,"ble_rx_drop":1,"rx_stack":2140}
```

`wifi`, `ble` and `ble_ext` say whether the Wi-Fi sniffer, BLE scanning and
BT5 extended scanning started. `caps` is the board's capability list (as
in the BLE Device Info, above); the heartbeat carries it every fifth beat,
for an app that attaches after boot. Boards add their own boot fields
(`display`, `vcom`, `mode`). Optional heartbeat fields: `ble_drop` and
`ble_rx_drop`, lines dropped going to and coming from the phone, when there
were any, and `rx_stack`, the decode task's least free stack in bytes.

### Commands

Hosts (the Mac app over USB, the phone app over BLE) send commands the
same way, one JSON object per line of at most 1,600 bytes; a reply goes
only to the host that asked.

| Command | What it does |
| --- | --- |
| `{"cmd":"set_time","utc":1790000000}` | Sets the clock the match log (and screens) use. A time before 2024 or past 2106 is refused. The T5 also sets its RTC and answers `{"type":"time","utc":…,"set":true,"rtc":"2026-09-23T12:00:00Z"}` with what the RTC chip reads back (`"rtc":null` when it cannot vouch for it), or, for a `utc` it refuses, `{"type":"time","set":false,"rtc":null,"err":"bad utc"}` |
| `{"cmd":"set_home","lat":…,"lon":…,"acc":12,"src":"phone"}` | The observer's position; `acc` (metres) and `src` optional. Out-of-range or missing coordinates are ignored |
| `{"cmd":"feed","on":true}` | The live feed on or off for this link (over BLE it starts off; USB always has it); answers `feed_status` |
| `tfr_clear`, `{"cmd":"tfr_add","id":"…","pts":[[lat,lon],…]}` | The flight restrictions around the host: at most 16 polygons of 3 to 24 points (points past 24 are dropped) |
| `{"cmd":"log_get"}`, `log_clear` | The match log (below); `log_clear` answers `log_cleared` |
| `fs_ls`, `fs_begin`, `fs_data`, `fs_end`, `fs_rm` | Map tile sync (SenseCAP and T5; the T-Embed and AMOLED answer `fs_err`) |
| `traffic`, `traffic_done` | ADS-B aircraft for the traffic rules (boards with `traffic` in `caps`, the T5) |
| `wifi_status`, `wifi_scan`, `wifi_join`, `wifi_forget`, `wifi_mode` | The T5's Wi-Fi (below) |

Tile sync writes only `/tiles/<z>/<x>/<y>.png` (decimal numbers, checked by
`firmware/common/tile_path.h`), 256 KB at most per file and never more than
the filesystem can hold, and `fs_rm` removes only plain paths inside
`/tiles`; anything else is refused with `fs_err`.

### Match log

`log_get` answers with one line per ended record, oldest first, then one
per contact still being tracked, then a `log_done` line:

```json
{"type":"log","seq":7,"i":7,"active":false,"uas":"1581F5FHD23AB00D","mac":"60:60:1F:AA:BB:CC",
 "srcs":5,"fmts":1,"ua_type":2,"first":1790000000,"last":1790000312,"dur":312,
 "lat":37.80390,"lon":-122.46400,"max_h":118,"peak_rssi":-58,
 "auth_state":"none","tfr":true,"emerg":false,"msgs":644}
{"type":"log","seq":null,"i":null,"active":true,"uas":"1581F20000D9A03",...}
{"type":"log_done","n":1,"live":1,"total":8,"clock":true,"next":8,"oldest":7}
```

`srcs` is a bit mask (1 Wi-Fi beacon, 2 NAN, 4 BLE), `fmts` another (1 ASTM
F3411, 2 GB 46750). `first` and `last` are UTC seconds, 0 when the clock was
not set when the record was made; `clock` in `log_done` says whether it is
set now. An ended record's `seq` numbers it for good (`i` is the same
number, kept for older clients); a live contact has `"active":true` and
`"seq":null`, and gets its number only when it ends. `total` counts every
record ever written.

Incremental sync: store `next` and ask `{"cmd":"log_get","since":<next>}`
next time; only records with `seq >= since` come back, and live contacts
always come again (still live, or ended with their number), so nothing is
skipped. `oldest` is the lowest `seq` still held: a cursor below it has
missed records that rotated out of the 48-record ring. A cursor above
`total` means the log was cleared (or this is another receiver): start
again from `oldest`. `"after_utc":<s>` additionally keeps only records and
live contacts last heard at or after that UTC second.

### Traffic lines

The Mac and phone apps push the ADS-B aircraft they fetch to a receiver
that takes them, every 10 seconds, at most 6 aircraft per line, nearest
first, then a `traffic_done` that installs the set (an empty set when none
came before it):

```json
{"cmd":"traffic","t":1727000000,"age_s":2,"ac":[{"hex":"a1b2c3","cs":"UAL123","ty":"B738",
 "lat":37.8,"lon":-122.4,"altg_m":820,"altb_ft":2650,"gs_kt":180,"trk":270,"vr_fpm":-640,
 "sq":"7700","em":1,"age_s":3},{"hex":"a0ad1d","cs":"UAL1668","lat":37.62,"lon":-122.39,
 "gnd":1,"gs_kt":0,"age_s":24}]}
{"cmd":"traffic_done","n":2,"age_s":2}
```

`gnd` marks an aircraft on the ground. Every field, and how the rules use
it, is documented at the top of `firmware/common/traffic.h`.

### T5 Wi-Fi lines

`{"cmd":"wifi_status"}` answers a `wifi_status` line (state, mode,
interval, network, IP, channel, signal, last sync, ADS-B age, TFRs and
aircraft held, saved networks). `{"cmd":"wifi_scan"}` answers one
`{"type":"wifi_net","ssid":…,"rssi":…,"secure":…,"saved":…,"ch":…}` per
network, then `wifi_scan_done`. `{"cmd":"wifi_join","ssid":…,"psk":…}`
(no `psk`: the saved one; `""`: open), `{"cmd":"wifi_forget","ssid":…}` and
`{"cmd":"wifi_mode","mode":"off|sync|stay","every_min":15}` answer
`wifi_status`, and are refused with
`{"type":"wifi_err","cmd":…,"reason":…}` unless they come over the paired
BLE link or the T5's Wi-Fi setup screen was opened in the last 5 minutes.
Every host also sees `{"type":"net","state":…}` lines as the board joins,
syncs (`"synced"`, with what worked, what failed, and its internal-RAM
figures), loses or leaves a network. The exact fields are in the header of
`firmware/common/net_sync.h`.

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
| `ORECCHINO-TX-WIFI` | WiFi beacon, vendor IE, channel 6 | 60 m |
| `ORECCHINO-TX-NAN` | WiFi NAN service discovery frame | 75 m |
| `ORECCHINO-TX-BLE5` | BLE 5 extended advertising, 1M PHY | 90 m |
| `ORECCHINO-TX-BLELR` | BLE 5 extended, coded PHY (long range) | 105 m |
| `ORECCHINO-TX-BLE4` | BLE 4 legacy, one message per advertisement | 120 m |

Every path transmits once every 5 seconds, which keeps the air quiet on a
bench full of receivers. A message pack carries Location each time; the
paths that send one message per transmission (BLE4, and the SINGLE format
variant) take five transmissions, 25 seconds, to cycle through all of them.
This is slower than the 1 Hz Location rate a real aircraft must keep.

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

One script runs every suite: the generated tables, the flash script's
clock step, the C and C++ firmware tests, the render checks, the Mac app's
tests and the phone app's (`flutter test`). A suite that cannot run here
(no Adafruit GFX fonts for the render checks, no `flutter` on the `PATH`)
prints a `SKIP` line, and the skips are listed again at the end, so a
missing suite is never mistaken for a pass. `ORECCHINO_SKIP="render app
mobile"` skips suites on purpose. Test binaries go in a private temporary
directory, so two runs at once cannot overwrite each other's.

CI (`.github/workflows/ci.yml`) runs the same script on macOS (with the app
and phone suites in jobs of their own, and any other `SKIP` failing the
job), `swift test`, `flutter analyze` and `flutter test`, and compiles
every board sketch with the pinned esp32 core and library versions and the
FQBNs the flash scripts use. Nothing in CI touches hardware.

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
the transmitter's off switches actually silencing its BLE advertising
sets and its once-every-5-seconds schedule, the JSON writer's numbers
against printf's, repeated frames reported once a second, and the match
log recording expired and evicted contacts, surviving a save and reload,
and answering `log_get` and `log_clear`, the incremental sync (`since`,
`next`, `oldest`, live contacts, a cleared log), the saved home, the output
routing (replies to the asking link only, the live feed to BLE only when
asked, over-long lines dropped whole) and the BLE link's contract against
a fake transport. The ADS-B traffic rules (`tests/traffic_test.cpp`) run
every shared vector in `tests/vectors/traffic/` through the firmware's own
parser — the Mac and phone apps run the same files — and the T5's Wi-Fi
(`tests/net_test.cpp`) runs the real `net_sync.h` state machine on a fake
radio, clock and fetcher (sync windows, join failures and back-off, STAY
mode, the `wifi_*` commands and who may send them), and the parsers on
recorded FAA and adsb.lol answers in `tests/vectors/net/`.

The T5 board's drawing code is rendered on the host too, with the
real font bitmaps, against a stress fixture of twelve contacts sharing a
serial prefix: every scene must come out with no two text runs colliding,
and the selection must survive a re-sort, an alert and an expiry. The
scenes include the Wi-Fi screens and keyboard, pairing, and traffic on the
table, map, side view and glance screen (they are written to
`/tmp/t5_*.pgm` for eyes; `T5_OUT` moves them). That check needs the
Adafruit GFX library's `Fonts/` in the Arduino sketchbook's `libraries/`
(`~/Documents/Arduino`, or `$ARDUINO_DIRECTORIES_USER`) and is skipped
without it. App tests cover the serial format, checksums, tile math,
identity conflicts between tracks, tile-sync state, reading, ordering,
syncing and exporting the match log, the traffic rules on the shared
vectors, and the ADS-B service on a recorded adsb.lol answer with a fake
clock. The phone app's tests are listed in `mobile/README.md`.

## Plans

- [`docs/plans/mobile-app-and-t5-wifi.md`](docs/plans/mobile-app-and-t5-wifi.md):
  an iOS and Android app that pairs with the receivers over Bluetooth LE
  (live contacts, the history, the phone's position and time), and Wi-Fi on
  the T5 for TFRs, ADS-B and map tiles, joined from its own screen; and
  ADS-B traffic alerts (manned aircraft near a detected drone) on the T5,
  the phone and the Mac. Largely built; its status section says what is
  done, what changed on the way, and what is left.
- [`docs/mockups/orecchino-traffic-alerts.html`](docs/mockups/orecchino-traffic-alerts.html):
  the traffic alert designs for the T5, the phone and the Mac.

## License

GPL-3.0-or-later — see [LICENSE](LICENSE). Third-party components are
listed in [THIRD_PARTY.md](THIRD_PARTY.md); all are GPL-compatible. Map
tiles are fetched by the user and are not part of this repository.
