# Orecchino Mobile (`orecchino_mobile`)

Remote ID and ADS-B traffic monitor for iOS and Android, built with Flutter
(Dart 3). It pairs with an Orecchino receiver over Bluetooth LE, shows what the
receiver hears on a heading-up radar, keeps the receiver's history on the
phone, and warns when a manned aircraft reported over ADS-B is near a drone.
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
  include `traffic`, the ADS-B set every 10 s (`traffic` / `traffic_done`
  lines, `TrafficWire.hostLines`). A command with no link throws; nothing is
  dropped silently.
- **History sync** (`core/sync/sync_engine.dart`, the protocol of
  `firmware/common/rx_core.h` `emit_log`): ended records are stored by seq,
  contacts still live (`"active":true,"seq":null`) replace the detector's
  previous live set, the cursor becomes `log_done.next` only when every record
  was stored, `oldest` above the cursor is reported as a gap, and a cursor
  above `total` (the detector's log was cleared) starts a new log epoch so
  new seqs never overwrite older history.
- **Live radar**, heading-up from the compass (north-up and said so when there
  is none): drones as dots with heading ticks, aircraft as outlined diamonds
  with a 60-second time ghost, and a **separation bridge** between a drone and
  the aircraft near it, labelled with horizontal and vertical separation.
  Range and bearing come from the phone's own position (the firmware's
  `ui_bearing`/`ui_dist_m` formulas, `core/geo.dart`); without a position they
  are blank, never taken from somewhere else. Contacts go stale after 60 s
  and are removed after 10 minutes; the firmware's "unknown" markers
  (altitude -1000, speed -1, direction -1, the 0,0 no-fix band) become blank
  values, as in the Mac app.
- **ADS-B traffic near your drones** (`core/traffic/traffic_rules.dart`, a port
  of `firmware/common/traffic.h` tested on `tests/vectors/traffic/`, fed from
  adsb.lol by `core/traffic/adsb_source.dart`): `TRAFFIC NEAR DRONE <id>`,
  `TRAFFIC CONVERGING WITH <id>, <n> S`, `LOW TRAFFIC <bearing> <km>` and
  emergency squawks, each with the data age, in km and m (aircraft altitude
  in feet). These are reported positions, not predictions, and not every
  aircraft broadcasts ADS-B: the most the app says about absence is "no ADS-B
  traffic reported within 3 km".
- **Alerts** (plan §8.4): a local notification per drone-aircraft pair at most
  every 5 minutes (time-sensitive on iOS for warnings; Android channel
  "Traffic near drones", high importance) with **Show** and **Mute 10 min**;
  drone alerts (EMERGENCY REPORTED, ID SIGNATURE INVALID) while a detector is
  connected; three short haptic pulses for traffic, one for drone alerts; an
  optional spoken callout ("Traffic, 2 o'clock, 1.1 kilometres, 2,600 feet,
  descending.", off by default). The banner adds the clock position relative
  to where the phone points. On Android an ongoing notification carries the
  active warning (updated at most every 5 s) and a foreground service says
  "Orecchino connected to 1 detector" while a detector is connected.
- **Find:** a big arrow toward the chosen drone or aircraft as you turn.
- **History:** every synced record, live ones marked LIVE, with alerts in
  words (EMERGENCY REPORTED, IN TFR, ID SIGNATURE INVALID, TEST KEY).
- **T5 Wi-Fi setup** over BLE (boards with the `wifi` capability): scan,
  join (open, with a password, or a saved network), forget, and the mode
  (Sync every N min / Stay connected / Off) as the board reports it, with the
  commands and replies of `firmware/common/net_sync.h` (`wifi_status`,
  `wifi_scan` -> `wifi_net` ... `wifi_scan_done`, `wifi_join`, `wifi_forget`,
  `wifi_mode`, refusals as `wifi_err`).
- **Demo detector** (Detectors > Settings): made-up drones, history and one
  aircraft, labelled SIMULATED everywhere.
- **Accessibility:** every radar mark and list row has a screen-reader label
  with the same words the screen shows (and is a 44 pt tap target); text
  colours are at least 4.5:1; text follows the system size up to 2x and the
  screens scroll or wrap instead of clipping; alerts are words, never colour
  alone.

## Privacy

Drone and operator positions and the history stay on the phone; nothing is
uploaded, and Android backup / device transfer of app data is disabled. ADS-B
requests go to adsb.lol with the phone's position rounded to 0.01° (about
1 km), every 10 s while the app is open and the ADS-B setting is on.

## Permissions

- **iOS** (deployment target 16.0): `NSBluetoothAlwaysUsageDescription`,
  `NSLocationWhenInUseUsageDescription`, `UIBackgroundModes` =
  `bluetooth-central`, and the Time Sensitive Notifications entitlement
  (`ios/Runner/Runner.entitlements`; add the capability to the App ID when
  signing).
- **Android:** `BLUETOOTH_SCAN` (`neverForLocation`), `BLUETOOTH_CONNECT`,
  legacy `BLUETOOTH`/`BLUETOOTH_ADMIN` up to API 30, fine/coarse location,
  `INTERNET`, `POST_NOTIFICATIONS`, `VIBRATE`, `FOREGROUND_SERVICE` +
  `FOREGROUND_SERVICE_CONNECTED_DEVICE`; `allowBackup="false"` and
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
- `lib/core/traffic/`: the shared traffic rules, the adsb.lol source.
- `lib/core/alerts/`: notification policy and words (`alert_policy.dart`),
  notifications / haptics / speech (`notifier.dart`).
- `lib/core/location/`: phone position and compass, with their failures.
- `lib/data/`: drift schema 2 (detectors with cursor, log epoch and pin;
  detections keyed by epoch + seq or by live contact; settings).
- `lib/features/`: `live`, `find`, `history`, `detectors` (with the Wi-Fi
  sheet). `lib/ui/`: theme tokens, traffic banner, card and bridge badge.

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
listener, released on dismiss; every state), the alert policy and words, the
adsb.lol mapping, contrast, screen-reader labels, and the Live screen at 2x
text. The traffic rules run every shared vector in `tests/vectors/traffic/`.

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
- iOS state restoration for background BLE (`bluetooth-central` is declared;
  the app does not yet restore its central manager after being terminated).
- History: the timeline scrubber, map replay and CSV export of plan §5.3.
- Find: haptic ticks by range; warmer/colder for contacts without a position.
- TFR fetch on the phone and push to boards (`tfr_add`).
- The `live_points` table (schema 2) is declared for the 24 h live-track
  ring of plan §5.2 but nothing writes or reads it yet.
- A map (plan §5.3; the plan names `flutter_map` and `latlong2`) and
  riverpod state are not used; add those packages back when the code does.
