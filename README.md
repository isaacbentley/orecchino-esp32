# Orecchino

A little ear for drone Remote ID. Orecchino pairs a **Seeed Studio XIAO
ESP32-C3** sniffer with a **native macOS app**: the board hears ASTM F3411 /
Open Drone ID broadcasts and streams them as JSON over USB; the app plots
drones and their operators live on a dark MapKit map, orecchiette-style.

```
 [drone]  ~~WiFi beacon / NAN / BLE~~>  [XIAO ESP32-C3]  --USB JSON-->  [Orecchino.app]
```

Receive-only on every path: nothing is transmitted on either radio.

## Firmware — `firmware/orecchino_fw`

Listens simultaneously on:

| Path | Details |
| --- | --- |
| WiFi beacon + probe resp. | Vendor IE type `0x0D`, OUI `FA:0B:BC` (ASD-STAN) or `90:3A:E6` (Parrot) |
| WiFi NAN | Public action frames, service `org.opendroneid.remoteid` (spec-locked to channel 6) |
| Bluetooth LE | Service data UUID `0xFFFA` **or** draft-era mfg-specific AD (`0xFF`, code `0x0200`), app code `0x0D` — legacy BT4 and BT5 extended advertising on the 1M and coded (long-range) PHYs |

Channel plan: the radio parks on channel 6 (75% dwell — NAN lives there and
it's the Open Drone ID beacon default) with 200 ms visits to 1 and 11;
20 MHz-wide channels on 5 MHz spacing mean `{1,6,11}` hears the whole
2.4 GHz band. Modem power save is off (`WIFI_PS_NONE`) so promiscuous RX
isn't gated. Heartbeats carry per-path match counters (`rid_w/rid_n/rid_b`)
plus `pfail` so "why no NAN?" is answerable in the field.

BLE uses [NimBLE-Arduino](https://github.com/h2zero/NimBLE-Arduino) compiled
with `CONFIG_BT_NIMBLE_EXT_ADV=1` (set in `firmware/orecchino_fw/build_opt.h`,
which the ESP32 core picks up automatically) — the core's own precompiled
NimBLE has extended advertising compiled out. BLE reports include which PHY
carried the payload (`"phy":"coded"` = long range). The C3 is 2.4 GHz-only,
so 5 GHz beacon Remote ID is out of reach.

Decoded messages (Basic ID, Location, Self ID, System, Operator ID — singles
or message packs) are emitted as one JSON object per line at 115200 baud on
the native USB CDC port, with a `{"type":"hb"}` heartbeat every 2 s.

Build + flash:

```bash
arduino-cli lib install "NimBLE-Arduino"
```

```bash
arduino-cli compile -b esp32:esp32:XIAO_ESP32C3:PartitionScheme=huge_app firmware/orecchino_fw
arduino-cli upload  -b esp32:esp32:XIAO_ESP32C3:PartitionScheme=huge_app -p /dev/cu.usbmodemXXXX firmware/orecchino_fw
```

## macOS app — `app/`

SwiftUI + MapKit, no dependencies, builds with Command Line Tools only
(macOS 14+):

```bash
app/Scripts/make_app.sh     # produces app/build/Orecchino.app
open app/build/Orecchino.app
```

- Dark map with per-drone colour, heading arrows, breadcrumb trails,
  operator position markers and drone↔operator sight lines; marker ink
  goes freshness-grey when a track ages out while its trail keeps the
  identity colour
- **FAA TFR overlay**: active Temporary Flight Restriction polygons from
  tfr.faa.gov's GeoServer (WFS layer `TFR:V_TFR_LOC`), refreshed every
  15 min, with per-zone NOTAM cards; toolbar toggle
- Sidebar: live drone list with recency micro-bars, source/long-range
  badges, RSSI and staleness; click to fly to a drone
- Detail card: six-field vitals grid (RSSI meter, height, speed, operator
  distance, age, link) above grouped Identity / Position / Operator fields;
  absent values render as dimmed em-dashes, never fake zeros; an evidence
  string (`BL·Y·`) shows which ODID message types have actually been decoded
- Spoof heuristic: flags a drone whose claimed operator is >15 km away
- Auto-detects the ESP32's serial port and reconnects on unplug
- **Demo** toolbar toggle injects two simulated drones for UI testing
  without hardware
- Tracks merge across WiFi/BLE by UAS ID (trails and counters merge too);
  stale tracks dim after 30 s and expire after 10 min

## Feed format

```json
{"type":"rid","src":"ble","mac":"AA:BB:CC:DD:EE:FF","rssi":-61,"phy":"coded",
 "basic_id":[{"id_type":1,"ua_type":2,"uas_id":"1581F..."}],
 "loc":{"status":2,"lat":37.1234567,"lon":-122.1234567,"alt_geo":82.0,
        "alt_baro":80.5,"height":60.0,"height_ref":0,"speed":8.0,
        "vspeed":0.5,"dir":123,"ts":1801.2},
 "self_id":{"desc_type":0,"desc":"Survey"},
 "system":{"op_lat":37.12,"op_lon":-122.12,"op_alt":12.0,"op_loc_type":1,
           "area_count":1,"ts":238912345},
 "op_id":{"id_type":0,"id":"FIN87astrdge12k8"}}
```

Anything speaking this schema over a serial port works as a source — the SDR
pipeline in [orecchiette](https://github.com/isaacbentley/orecchiette) could
feed it just as well as the ESP32.
