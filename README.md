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
| WiFi beacon | Vendor IE, ASD-STAN OUI `FA:0B:BC`, type `0x0D`; channels 1–13, hop biased to 6 |
| WiFi NAN | Public action frames, service `org.opendroneid.remoteid` (discovery channel 6) |
| Bluetooth LE | Service data UUID `0xFFFA`, app code `0x0D`, legacy advertising (BT4)* |

\* The stock Arduino ESP32 core builds NimBLE without `BLE_EXT_ADV`, so BT5
extended/long-range advertising is not received. Compliant transmitters
dual-broadcast on legacy BT4, which is received. The extended-scan path is in
the source behind `#if MYNEWT_VAL(BLE_EXT_ADV)` and lights up automatically
if the core ever enables it. The C3 is 2.4 GHz-only, so 5 GHz beacon Remote
ID is out of reach.

Decoded messages (Basic ID, Location, Self ID, System, Operator ID — singles
or message packs) are emitted as one JSON object per line at 115200 baud on
the native USB CDC port, with a `{"type":"hb"}` heartbeat every 2 s.

Build + flash:

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
  operator position markers and drone↔operator sight lines
- Sidebar: live drone list (UAS ID, sources, RSSI, height, age), click to
  fly to a drone; selection shows a full detail card
- Auto-detects the ESP32's serial port and reconnects on unplug
- **Demo** toolbar toggle injects two simulated drones for UI testing
  without hardware
- Tracks merge across WiFi/BLE by UAS ID; stale tracks dim after 30 s and
  expire after 10 min

## Feed format

```json
{"type":"rid","src":"ble","mac":"AA:BB:CC:DD:EE:FF","rssi":-61,
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
