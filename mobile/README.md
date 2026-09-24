# Orecchino Mobile (`orecchino_mobile`)

Remote ID monitor for iOS and Android, built with Flutter (Dart 3). It pairs
with an Orecchino receiver over Bluetooth LE, shows the drones it hears in a
heading-up 3D sky, and keeps the receiver's history on the phone. The UI is
Remote ID first: ADS-B is used only for conflict detection and resolution. A
manned aircraft appears only while an alert names it (near or converging with
a drone, or low in UAS airspace), and every alert leads with what the drone
should do.
Design and protocol: [`docs/plans/mobile-app-and-t5-wifi.md`](../docs/plans/mobile-app-and-t5-wifi.md)
§3, §5 and §8.4; phone designs in [`docs/mockups/`](../docs/mockups/).

## What it does

- **Pairing.** Scan (Nordic UART Service), choose a detector, and the phone
  checks it before trusting it: it reads the Orecchino device-info
  characteristic (`fw` must be `orecchino`, `proto` >= 1), then bonds (the
  detector shows passkey **123456**; type it within 10 s or the detector hangs
  up) and subscribes to TX, which the firmware allows only on an encrypted
  link. The verified detector is then **pinned**: the app reconnects to it by
  itself, refuses a different board appearing under the same ID, and only a
  pinned, verified detector is ever sent the phone's position. *Forget*
  unpins it.
- **On every connection:** `feed on`, `set_time`, `set_home` (phone position,
  accuracy, `"src":"phone"`), then `log_get` from the stored cursor; after
  that `set_time`/`set_home` every 60 s, and to boards whose capabilities
  include `traffic`, the phone's ADS-B set every 10 s (`traffic` /
  `traffic_done` lines, `TrafficWire.hostLines`). A command with no link throws; nothing is
  dropped silently.
- **History sync** (`core/sync/sync_engine.dart`, the protocol of
  `firmware/common/rx_core.h` `emit_log`): ended records are stored by seq,
  contacts still live (`"active":true,"seq":null`) replace the detector's
  previous live set, the cursor becomes `log_done.next` only when every record
  was stored, `oldest` above the cursor is reported as a gap, and a cursor
  above `total` (the detector's log was cleared) starts a new log epoch so
  new seqs never overwrite older history.
- **Live sky**, heading-up from the compass (north-up and said so when there
  is none): a full-screen 3D dome (`features/live/sky_projection.dart`, a
  perspective camera over a ground plane of range rings and compass ticks)
  with every drone on a height stem above its ground position. Drones are
  glowing orbs with heading ticks; a radar sweep re-lights fresh contacts.
  An aircraft is drawn only while an alert names it: an outlined chevron
  (never filled) with a dashed 60-second track projection and time-ghost
  dots, and a **separation bridge** from its drone (low traffic: from the
  nearest drone, or from you when it is within 3 km of you) with the
  horizontal and vertical separation (low traffic: height above ground)
  floating on it. A drone's **operator** (from its System message) is a
  ground pin (an outlined map pin with a dot, in the drone's colour, never an
  orb or a chevron) joined to its drone by a thin dotted line and labelled
  "operator 420 m SW" (from the drone). Anything **beyond the selected range**
  is pinned to the outer ring at its true bearing as an edge marker: a
  chevron pointing outward at ground level, labelled "<id> · 4.3 km ›", a
  44 pt target read as "…, beyond 3.0 km, 4.3 km NE, shown on the edge". Labels
  keep clear of each other. Drag to rotate and tilt, pinch for 1 / 3 / 5 km,
  double-tap to reset; **3D / 2D / Map** switches between the dome, a flat
  top-down radar and the map. Heights
  are drawn on a compressed scale; the labels carry the real numbers. The
  drones are in a glass sheet (peek: the drone count, the nearest drone and
  the **conflict-watch chip**, the rules' status line: "conflict watch on, no
  ADS-B conflicts, data 6 s old", "TRAFFIC DATA STALE, ...", "CONFLICT WATCH
  OFF: ..."; pulled up: a card per drone with source badges, its alert's
  action and geometry, height, age and a sparkline of its signal) and the sky
  re-fits above it (a card with an operator reads "Operator 420 m from
  drone · 1.2 km from you"). There are no aircraft rows or counts. A capsule at the
  top shows the drones ("2 drones · nearest 2A002 485 m") and morphs into the
  alert when there is one: the action first ("GIVE WAY: DESCEND AND LAND
  D9A11", "BE READY TO LAND DRONES"), then the geometry ("AIRCRAFT 80 M
  ABOVE, 1.1 KM NE, CLOSEST IN 20 S"), then the rule's words and the data
  age; tap it for the aircraft's card.
  **Map mode** (`features/live/live_map.dart`, flutter_map): Esri's World
  Dark Gray Canvas raster tiles by default (no key; User-Agent names the
  app), tinted to the night-sky palette, with Esri's attribution always on
  screen (tap it for the full text). CARTO Dark Matter now needs an API key
  (without one it serves "API KEY REQUIRED" tiles), so Detectors > Settings >
  Map tiles takes any `https://…/{z}/{x}/{y}` template with its key and its
  attribution instead. You and range rings for the selected range;
  drones as glowing marks with heading ticks and a short trail, operators
  with their links, alerting aircraft with their track and bridge (only
  those an alert names); follow me / fit all, drag, pinch and twist. Tiles
  are cached on the phone (flutter_map's built-in cache, 50 MB cap) so a
  revisited area works offline; nothing is prefetched. Without tiles the
  marks stay on a plain dark grid and the map says "Map offline: showing a
  plain grid".
  Range and bearing come from the phone's own position (the firmware's
  `ui_bearing`/`ui_dist_m` formulas, `core/geo.dart`); without a position they
  are blank, never taken from somewhere else. Contacts go stale after 60 s
  and are removed after 10 minutes; the firmware's "unknown" markers
  (altitude -1000, speed -1, direction -1, the 0,0 no-fix band) become blank
  values, as in the Mac app.
- **ADS-B conflict watch** (`core/traffic/traffic_rules.dart`, a port of
  `firmware/common/traffic.h` tested on `tests/vectors/traffic/`, fed from
  adsb.lol by `core/traffic/adsb_source.dart`): `TRAFFIC NEAR DRONE <id>`
  and `TRAFFIC CONVERGING WITH <id>, <n> S` (warnings) and `LOW TRAFFIC
  <bearing> <dist>` (caution: an airborne aircraft within 3 km of you or a
  live drone, below 460 m above ground), each with its resolution for the
  drone (14 CFR 107.37(a): the drone gives way) and the data age.
  `core/traffic/traffic_words.dart` puts the action first everywhere. These
  are reported positions, not predictions, and not every aircraft broadcasts
  ADS-B; the status line never counts aircraft or claims the sky is empty.
  The query is small: **10 km around the phone** by default (5-30 km,
  Detectors > Settings); a live drone more than 3 km from the phone moves the
  centre to the middle of the phone and the drones and widens the radius
  until every live drone has 9 km around it, up to 30 km (`AdsbArea.plan`, a
  port of the firmware's `net_adsb_area`). Aircraft outside the area are
  dropped.
- **Alerts** (plan §8.4): a local notification per alert (a drone-aircraft
  pair, or a low aircraft) at most every 5 minutes, titled with the action
  and carrying the geometry, the rule, the aircraft and the data age
  (time-sensitive on iOS for warnings; Android channel "Traffic near drones",
  high importance) with **Show** (opens Live on the drone) and **Mute 10
  min**; drone alerts (EMERGENCY REPORTED, ID SIGNATURE INVALID) while a
  detector is connected; three short haptic pulses for traffic, one for drone
  alerts; an optional spoken callout ("Give way: descend and land D9A11.
  Traffic, 2 o'clock, 1.1 kilometres, 2,600 feet, descending.", off by
  default). Aircraft no alert names never notify. The Live alert capsule adds the clock
  position relative to where the phone points. On Android an ongoing notification carries the
  active warning (updated at most every 5 s) and a foreground service says
  "Orecchino connected to 1 detector" while a detector is connected.
- **This phone as a detector** (`core/native_rx/`, `core/odid/`; Detectors >
  Settings > "Use this phone as a detector", on by default): the phone hears
  Remote ID itself (Bluetooth 4 legacy and Bluetooth 5 extended advertising;
  on Android also Wi-Fi NAN and, slowly, Wi-Fi beacons; on iOS Bluetooth 4
  only, while the app is open), with the settings showing what this phone
  can hear. One Bluetooth scan coordinator serves both the detector picker
  and the phone's receiver. The phone's frames go straight to the live
  tracker, never to the detector sync. **Fusion:** one track per drone
  whoever heard it (by UAS ID, then MAC; iOS gives a peripheral UUID, not a
  MAC, so the UAS ID joins them), the freshest position winning, each
  sensor keeping its own last heard, RSSI and PHY; the phone's "unverified"
  never replaces a detector's signature verdict. **Sensor chips** on every
  drone (sky label, card, Find, details with per-sensor RSSI and last heard,
  History records): "📱 BLE4", "📱 BLE5 LR", "📱 NAN", "📱 Wi-Fi (slow)",
  "T5 · Wi-Fi", "T-Embed · NAN"; greyed with their age after 10 s, gone
  after 60 s; read as "heard by this phone over Bluetooth 4 and by T5 over
  Wi-Fi". What the phone hears goes into History as its own records ("This
  phone": one per drone per spell of hearing it, live until a minute
  without a frame), touching no detector's sync cursor.
- **Drone details** (`features/details/`): every field the detector's `rid`
  lines carry, grouped Identity (UAS IDs and ID types, make and model from
  the serial where the local table knows it, UA type, classification,
  operator ID, self-ID), Position (coordinates, copyable; geodetic and
  pressure altitude; height and its reference; accuracies; position time),
  Motion, Operator (location, altitude, from the drone and from you),
  System (area, classification, system time), Signal (transports and PHY,
  signal now and peak with a sparkline, MACs, SSID and its match, message
  count, first and last heard, protocol), Authentication (verdict, type,
  pages, the time the signature's first page carries) and Alerts
  (emergency, "IN TFR 6/3221" from a detector with TFRs loaded, ID
  signature, ADS-B alerts with their action). Classification reads "EU ·
  Specific · C2"; accuracies are the F3411 table's "< 3 m", "< 10 m",
  "< 0.5 s". Anything not broadcast, or not in the detector's line (firmware
  before 0.7 sends no accuracies, area, class, auth time or TFR), reads "not
  reported", never a made-up value. Opened from the selected drone's card
  (a sky mark or a card; a long press on a card), Find's target, and a
  History record (what the log keeps).
- **Find ("point at the sky"):** a head-up pointer to the chosen drone, its
  operator, or an aircraft (only while an alert names it, as part of that
  alert, with the alert's action above the pointer): left/right from the bearing, and its
  elevation above the horizon (from its height and distance; "about" for
  aircraft, whose altitude is barometric). A lock-on ring tightens as the phone comes round and says ON
  TARGET; haptic ticks for each 15-degree step toward it, a tap on lock, and
  one per step closer (50 m steps under 1 km, 250 m beyond; the Haptics
  setting turns them off). Without a compass it is a north-up sky plot
  (horizon at the rim, overhead at the centre) and says so.
- **History:** an activity ribbon over the last 6 h / 24 h / 7 d (alert bins
  marked) that you scrub; the record under the cursor replays on a mini sky
  dome, and a record tapped in the list replays in a sheet over it (the list
  keeps its place). Records keep one position and the highest height, so the
  replay shows that position and the climb, not a flown track. Below, the
  records grouped by day, live ones marked LIVE, alerts in words (EMERGENCY
  REPORTED, IN TFR 6/3221, ID SIGNATURE INVALID, TEST KEY); a record's
  details add its EU classification and whether it was still inside the TFR
  at its end. A record beyond 10 km
  replays pinned to the ring's edge. **Clear history…** (History's header,
  and a detector's card) offers three choices, each saying what it deletes
  and that it cannot be undone, each confirmed by a second, red button:
  this phone's records (every detector; pins, cursors and settings stay),
  the connected detector's log (`log_clear`, confirmed by `log_cleared`
  within 5 s or reported as a failure), or both (the phone's only if the
  detector confirmed). Whenever a detector says `log_cleared` (asked for, or
  cleared from its own screen) the phone starts a new log epoch for it and
  syncs from the start, keeps its own records, and says "History cleared on
  <detector>".
- **T5 Wi-Fi setup** over BLE (boards with the `wifi` capability): scan,
  join (open, with a password, or a saved network), forget, and the mode
  (Sync every N min / Stay connected / Off) as the board reports it, with the
  commands and replies of `firmware/common/net_sync.h` (`wifi_status`,
  `wifi_scan` -> `wifi_net` ... `wifi_scan_done`, `wifi_join`, `wifi_forget`,
  `wifi_mode`, refusals as `wifi_err`). **Wi-Fi paused: phone connected**
  while the phone's link holds the board's automatic windows (`"paused":
  "phone"` in `wifi_status`, `net` lines `paused` / `resumed`). When the
  board reports them, its **ADS-B radius** (5-30 km) and **map area** (1 km
  to what its flash holds, `tile_max_km`) are sliders sent as `wifi_config`,
  with the storage plan from its last `net` `synced` line ("Map: 3 km
  z12-15; 0.8 MB of 11.9 MB").
- **Demo detector** (Detectors > Settings): three made-up drones (one 4.3 km
  out, on the ring's edge at 3 km) with operators (one 2.6 km from its
  drone), two of them also "heard by this phone" (so both kinds of sensor
  chip show), history, and
  on a 6-minute cycle a Cessna that comes near drone 1 (low traffic, then a
  GIVE WAY warning) and a helicopter crossing low 2 km north of you (low
  traffic), with quiet time between; the board reports Wi-Fi paused by the
  phone and a map plan. Labelled SIMULATED everywhere.
- **Accessibility:** every sky mark and contact card has a screen-reader label
  with the same words the screen shows (and is a 44 pt tap target); text
  colours are at least 4.5:1 on every surface, on glass, and on the brightest
  colour the living background draws; text follows the system size up to 2x
  and the screens scroll or wrap instead of clipping (the tab bar's labels
  stop at 1.35x, as tab bars do); alerts are words, never colour alone; with
  Reduce Motion on, the sky, the sweep and the breathing lights stand still.
- **Landscape and tablets:** every screen works in both orientations on
  phones and iPads. On wide screens the Live contacts move into a side panel
  (with the view controls and the heading/status chips on top) and the sky
  fills the rest; on a phone on its side the tabs become a rail on the left,
  clear of the Dynamic Island. Find puts its pointer beside the readouts.
  The compass plugin reports where the top of the screen points in any
  orientation, so heading-up and Find's pointer stay right when the phone is
  turned.
- **Power modes** (Detectors > Settings > Power; `core/power/power_policy.dart`
  is the one table everything follows, by mode, foreground and visible tab):

  | | Full | Balanced (default) | Saver |
  |---|---|---|---|
  | Animation | 30 frames/s, each glass panel its own blur | aurora 24 frames/s at 1/4 resolution, glass panels share one blur | still sky, a denser tint instead of blur |
  | This phone's Bluetooth scan, in front | low latency, all PHYs | low latency on Live and Find, balanced elsewhere | balanced on Live and Find only |
  | ... in the background (Android) | balanced | low power (balanced for 2 min after a drone) | off |
  | Wi-Fi beacons / NAN (Android) | every 30 s / on | 60 s in front, 2 min behind / Live and Find only | off |
  | ADS-B | every 10 s | 10 s with a live drone or a traffic detector, else 60 s | 30 s with a live drone only |
  | Detector feed | on | on (a background digest needs the firmware; the feed stays on until the detector supports it) | on (same) |
  | Location | high accuracy | high on Live and Find, medium (50 m) elsewhere | medium; last fix in the background |
  | Compass | 15/s on Live and Find | 10/s on Live and Find | Find only |

  In every mode: ambient motion (aurora, sweep, glows, Find's lock pulse and
  pointer easing) runs on one shared timer (`ui/ambient_clock.dart`) at the
  mode's rate, not on the display's vsync (up to 120 Hz on ProMotion), and
  stops under Reduce Motion, in the background and, for the aurora, under
  Map mode; the sky's base layer repaints only when its marks or camera
  change; the compass has its own throttled listenable (at most 10 updates a
  second, 2° or more), so turning the phone repaints the sky and Find's
  pointer, not the whole app; the whole app is notified once a second, and
  the shell only when the alert level or the Live badge changes. ADS-B
  needs a position, and after a failed fetch it backs off (10 s doubling to
  5 minutes, never sooner than its usual interval). Android's Bluetooth scan is not thinned natively:
  flutter_blue_plus' divisor counts per device, and a Bluetooth 4
  transmitter rotates its message types, so it would drop whole types; the
  decoder's once-a-second rule drops repeats in Dart.
- **In the background:**
  - *Android:* "Watch in the background" (off by default) runs a native
    foreground service (`OrecchinoWatchService.kt`, types connectedDevice,
    plus location when it is granted; never dataSync) that keeps the app's
    one Flutter engine (`OrecchinoApplication.kt`, cached; MainActivity
    attaches to it) running with the app closed: the detector link, this
    phone's receiver at its background duty, the rules and the alerts carry
    on. Its notification reads "Orecchino watching · 2 drones · conflict
    watch on · T5 connected", with Open, Pause 1 h (alerts muted and this
    phone's receiver resting for an hour) and Stop (until the app is opened
    again). It starts only while the app is on screen. After pairing, the
    app asks Android to associate the detector as a companion device
    (`WatchPlugin.kt`): the app may then run and start its service in the
    background for it, Android 12+ wakes it when the detector comes into
    range (`DetectorPresenceService.kt`), and reconnecting is a pending
    connect (autoConnect: the Bluetooth controller connects when the
    detector is near, no app scanning). Without the association, or where
    the companion API is missing, the app retries a 15 s connect after 5 s,
    doubling to 60 s.
  - *iPhone:* "In the background your iPhone stays connected to your
    detector and alerts you. This iPhone's own receiver works only while
    Orecchino is open. Without a detector there are no background alerts. If
    you swipe Orecchino away, it stops until you open it again." The app
    opts into Core Bluetooth state restoration and keeps a pending connect
    (no timeout) to its detector, so iOS relaunches it when the detector
    reconnects. ADS-B and the rules run while those Bluetooth wakes keep the
    app running.

## Design system

**Themes** (Detectors > Settings > Theme; remembered, switched at once
without a restart, and "Sky" on first run). Every colour, type style and
radius comes from the active look (`lib/ui/theme/look.dart`: one `Palette`
per look, read through `OrecchinoColors`, `OrecchinoType` and
`OrecchinoTheme`); a switch rebuilds and repaints the whole tree and keeps
the screen's state.

- **Sky:** the night-sky palette below, frosted glass over the living
  aurora, a 3D sky of the drones.
- **Flat:** the design mockups (`docs/mockups/orecchino-traffic-alerts.html`,
  their dark scheme): ground #0B0F12, panels #12181C with a 1 px #243036
  rule and at most an 8 px radius, ink #E3E8EA, muted #8C9AA2, one teal
  accent #35D0BA, amber #E0A83A and red (#F27373, the mockups' #E05A5A
  lifted to keep 4.5:1). No aurora, no blur, no glows, sweeps or pulses; an
  alert is a dark banner of its colour (the mockups' #3A1414); Live is a
  top-down radar (rule-coloured rings, "▲ you face", drones as solid dots,
  aircraft as outlined diamonds, the separation bridge as one translucent
  band) or the map, with no 3D option; the map's tiles are tinted to the
  same neutrals. Type follows the mockups' stack, IBM Plex Sans Condensed
  (display), Plex Sans (text) and Plex Mono (identifiers and section
  heads), bundled under `assets/fonts/ibm_plex_*` (SIL Open Font License
  1.1, © IBM Corp., from github.com/IBM/plex releases; only the weights the
  look uses). With Saver, Settings suggests Flat.

The contrast test checks both palettes, and `test/theme_test.dart` checks
the switch and lays out every main screen in both looks (portrait, 2x text,
landscape).

`lib/ui/theme/`: `colors.dart` (a night-sky palette with avionics symbol
colours: aqua drones, starlight aircraft, amber caution, red warning, and the
three living-background palettes), `typography.dart` and `motion.dart`
(durations, curves, springs, `Motion.reduced`). `lib/ui/glass.dart` has the
frosted-glass panels, pills, tags and the breathing connection light;
`lib/ui/living_background.dart` draws `shaders/aurora.frag`, an aurora whose
colours follow the threat level (calm, caution, warning), with a static
gradient when shaders are unavailable (tests). Fonts are bundled, never
fetched: Space Grotesk (display and numbers), Inter (text) and JetBrains Mono
(identifiers), all SIL Open Font License 1.1, with their licences in
`assets/fonts/*/OFL.txt`. Numbers use tabular figures.

The app icon and launch mark (a sky dome over a ground ring, the phone at its
centre, a drone on its height stem, listening arcs) are authored as SVG in
`branding/`: `icon.svg` (full bleed), `icon_background.svg` and
`icon_foreground.svg` (Android adaptive layers, the motif inside the safe
zone) and `launch_mark.svg`. `tool/make_icons.sh` rasterises them (needs
`rsvg-convert` from librsvg and macOS `sips`) into the iOS AppIcon set (opaque,
no alpha) and LaunchImage, the Android legacy and adaptive mipmaps, and the
Android launch drawable; re-run it after editing a master.

## Privacy

Drone and operator positions and the history stay on the phone; nothing is
uploaded, and Android backup / device transfer of app data is disabled. ADS-B
requests go to adsb.lol with the query centre (the phone, or the middle of
the phone and far drones) rounded to 0.01° (about 1 km), every 10 s while a
drone is live or a detector takes traffic, otherwise every 60 s (see Power
modes), and only while the ADS-B setting is on. In Map mode the phone
fetches map tiles for the area on screen from Esri
(server.arcgisonline.com), or from the template you set, as any map does;
they are cached on the phone (up to 50 MB).

## Permissions

- **iOS** (deployment target 16.0): `NSBluetoothAlwaysUsageDescription`,
  `NSLocationWhenInUseUsageDescription`, `UIBackgroundModes` =
  `bluetooth-central`, and the Time Sensitive Notifications entitlement
  (`ios/Runner/Runner.entitlements`; add the capability to the App ID when
  signing).
- **Android:** `BLUETOOTH_SCAN` (`neverForLocation`), `BLUETOOTH_CONNECT`,
  legacy `BLUETOOTH`/`BLUETOOTH_ADMIN` up to API 30, fine/coarse location,
  `INTERNET`, `POST_NOTIFICATIONS`, `VIBRATE`, `FOREGROUND_SERVICE` +
  `FOREGROUND_SERVICE_CONNECTED_DEVICE` + `FOREGROUND_SERVICE_LOCATION` (the
  background watch), `REQUEST_COMPANION_RUN_IN_BACKGROUND`,
  `REQUEST_COMPANION_START_FOREGROUND_SERVICES_FROM_BACKGROUND` and
  `REQUEST_OBSERVE_COMPANION_DEVICE_PRESENCE` (an associated detector; the
  `companion_device_setup` feature is optional); `allowBackup="false"` and
  data-extraction rules that exclude everything. Core library desugaring is
  on (flutter_local_notifications needs it).

A denied permission or switched-off location is shown on the Live screen in
words, never swallowed.

## Architecture

- `lib/app/app_controller.dart`: wires link, sync, contacts, traffic and alerts;
  the only place that decides what is sent to a detector.
- `lib/core/protocol/`: line framing (`LineCodec`: bytes buffered, split on
  0x0A, decoded per complete line, 4 KB cap), message models as the firmware
  writes them (`HostMessage`), command builders (`HostCommands`).
- `lib/core/link/`: `DetectorLink`, what the screens need from a detector.
- `lib/core/ble/`: `BleService` (scan, connect, verify, pair, the state
  machine), `BleTransport` (flutter_blue_plus behind an interface, faked in
  the tests), `SimulatedDetector`.
- `lib/core/sync/`: history sync. `lib/core/live/`: live contacts.
- `lib/core/traffic/`: the shared traffic rules, the words order (action
  first), the adsb.lol source and its query area.
- `lib/core/alerts/`: notification policy and words (`alert_policy.dart`),
  notifications / haptics / speech (`notifier.dart`).
- `lib/core/location/`: phone position and compass, with their failures;
  the precision and the compass follow the power policy.
- `lib/core/power/`: the power policy (modes x foreground x tab) and the
  ADS-B schedule. `lib/core/background/`: the Android watch service and
  companion association over a method channel.
- `lib/data/`: drift schema 3 (detectors with cursor, log epoch and pin;
  detections keyed by epoch + seq or by live contact, with the TFR at the
  end, its id and the EU class since schema 3; settings).
- `lib/features/`: `live` (items, the 3D camera, the sky painter and scene,
  the alert capsule, the contact sheet), `find` (with its pure geometry and
  haptic cues), `history` (with the timeline logic), `detectors` (with the
  Wi-Fi sheet). `lib/ui/`: the design system (see above), the glass tab bar,
  the aircraft card and the bridge badge.

## Tests

```bash
flutter analyze   # must report no issues (rules in analysis_options.yaml)
flutter test
```

`test/` covers the line codec (split UTF-8 at every byte, the size cap), the
messages against firmware lines (unknown markers become null), bearing and
distance against the firmware formulas, the sync cursor (live records, gaps,
a cleared log, store failures), contact expiry and filtering, the BLE state
machine with a fake transport (verification, pinning, mid-pairing drops,
stale disconnects, chunked writes), the app controller (position only to a
pinned, verified detector; resume from the cursor), the Wi-Fi sheet (one
listener, released on dismiss; every state; paused by the phone; the board's
ADS-B radius and map area), the alert policy and words (action first; low
traffic), the adsb.lol mapping and query area, the demo's traffic cycle (a
warning, low traffic and quiet time), that an aircraft no alert names is never
drawn, listed, counted or announced, contrast, screen-reader labels, the Live screen at 2x text
and with Reduce Motion, the 3D sky camera, the Find elevation angle and haptic
cues (played on app updates, never on rebuilds), the History timeline, the
sparkline history, the aurora shader (it compiles and takes its uniforms),
text contrast over a star, and every screen on a phone on its side (1x and
2x text) and on an iPad in both orientations. The traffic rules run every shared vector in
`tests/vectors/traffic/`. `test/power_test.dart` covers the power policy
table, ADS-B gating and backoff, the app following the lifecycle and the
visible tab (scan duty, Wi-Fi paths, location, compass), the compass
throttle, the ambient clock, "Watch in the background" over a fake method
channel (start only on screen, Pause 1 h, Stop, companion association),
pending reconnects, and the frame budget of an idle Live screen (at most 30
frames a second in Balanced, 31 in Full, none but the once-a-second update
in Saver or with Reduce Motion; never the display's 120).

After changing `lib/data/db.dart`, regenerate `db.g.dart` with
`flutter pub run build_runner build`.

## Building

The app targets iOS and Android only (plan §5); there is no macOS, web or
desktop build. Identifiers: iOS bundle ID and Android application ID
`dev.bentley.orecchino.mobile` (the Mac app is `dev.bentley.orecchino`),
display name "Orecchino". The version is `version:` in `pubspec.yaml`
(`0.7.0+1`, matching firmware 0.7.0), which Flutter turns into
`CFBundleShortVersionString`/`CFBundleVersion` and
`versionName`/`versionCode`.

Toolchain, the minimum that builds both (checked with Flutter 3.47.5):

- **Android**: JDK 17 and the Android command-line tools, no Android Studio.
  `brew install openjdk@17` and `brew install --cask android-commandlinetools`,
  then `sdkmanager --sdk_root=$HOME/Library/Android/sdk --licenses` and
  `sdkmanager --sdk_root=$HOME/Library/Android/sdk "platform-tools"
  "platforms;android-36" "build-tools;36.0.0"`, and point Flutter at both:
  `flutter config --android-sdk $HOME/Library/Android/sdk --jdk-dir
  "$(brew --prefix openjdk@17)/libexec/openjdk.jdk/Contents/Home"`. The first
  Gradle build fetches the rest itself (platforms 34/35, CMake, the NDK):
  budget about 9 GB for the SDK plus `~/.gradle`.
- **iOS**: full Xcode (the Command Line Tools are not enough) and CocoaPods
  (`brew install cocoapods`; `flutter_compass` and `flutter_tts` have no
  Swift Package Manager support yet, the other plugins come through SPM).
  No simulator runtime is needed to compile.

```bash
flutter build apk --release          # build/app/outputs/flutter-apk/
flutter build ios --release --no-codesign
```

The iOS project targets iOS 16.0 (`ios/Podfile`, `Runner.xcodeproj`).
`pod install` warns that the Profile configuration has no Pods base
configuration; that is the Flutter template and only affects `--profile`
builds.

### Signing an Android release

The release build type is signed only with your upload key; it is never
signed with the debug key. Without the key the release build comes out
unsigned (not installable, not accepted by Google Play), so a debug-signed
release cannot ship by mistake. To sign:

1. Make an upload key once, and keep it out of the repository:
   `keytool -genkey -v -keystore ~/orecchino-upload.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload`
2. Create `mobile/android/key.properties` (ignored by `android/.gitignore`,
   never commit it):

   ```properties
   storePassword=<keystore password>
   keyPassword=<key password>
   keyAlias=upload
   storeFile=/Users/<you>/orecchino-upload.jks
   ```

3. `flutter build appbundle` (Play Store) or `flutter build apk --release`.

iOS signing is Xcode's: set the team in `ios/Runner.xcworkspace` and add the
Time Sensitive Notifications capability to the App ID (see Permissions).

## Follow-ups

- **Live Activity / Dynamic Island** (plan §8.4: compact leading an airplane
  glyph and `1.1 km`, trailing the clock position; expanded callsign, type,
  altitude and trend, separation, data age). It needs a native Widget
  Extension target in `ios/` (ActivityKit, `NSSupportsLiveActivities` in
  `Info.plist`, an `ActivityAttributes` struct shared by the app and the
  extension, and a method channel from `AlertSink.ongoing` to start, update
  and end the activity). Not added yet: it builds with the toolchain above,
  but testing it needs an iPhone or an iOS simulator runtime. Android's
  equivalent, the ongoing notification, is done.
- A firmware "digest" feed for the background (the detector sends only
  changes and alerts), so the feed need not hold a 30-50 ms connection
  interval with the app closed; until then the feed stays on.
- iOS: an opt-in "moving observer" (the `location` background mode, medium
  accuracy, 50 m) for a position that follows you with the app closed.
- Android: a native Bluetooth Remote ID scanner in the watch service that
  de-duplicates before the channel and reports the PHY.
- History: a map replay of real tracks (needs the `live_points` ring below)
  and CSV export of plan §5.3.
- Find: warmer/colder for contacts without a position; the phone's pitch
  (it would need an accelerometer plugin) so the pointer could lock on in
  elevation too, not only in bearing.
- TFR fetch on the phone and push to boards (`tfr_add`).
- The `live_points` table (schema 2) is declared for the 24 h live-track
  ring of plan §5.2 but nothing writes or reads it yet.
- riverpod state (plan §5.3) is not used; add the package when the code does.
- The live items and the sky do not yet raise "IN TFR" as an alert (only
  the details and History show it).
