import Foundation
import CoreLocation
import MapKit
import Testing
@testable import Orecchino

private func decode(_ s: String) throws -> RidMessage {
    try JSONDecoder().decode(RidMessage.self, from: Data(s.utf8))
}

@Suite struct RidMessageTests {
    @Test func heartbeatLine() throws {
        let m = try decode(#"{"type":"hb","up":34103,"wifi_frames":117,"ble_advs":4674,"rid":1,"dropped":0,"ch":6,"ble":true,"ble_ext":true}"#)
        #expect(m.type == "hb")
        #expect(m.wifi_frames == 117)
        #expect(m.ble_ext == true)
    }

    @Test func ridLineWithPhyAndNoVspeed() throws {
        // vspeed omitted = broadcast marked it unknown
        let m = try decode(#"{"type":"rid","src":"ble","mac":"AA:BB:CC:DD:EE:FF","rssi":-61,"phy":"coded","basic_id":[{"id_type":1,"ua_type":2,"uas_id":"1581F204C68D9A11"}],"loc":{"status":2,"lat":37.8039,"lon":-122.464,"alt_geo":100.0,"alt_baro":95.0,"height":60.0,"height_ref":0,"speed":5.0,"dir":90,"ts":1200.0}}"#)
        #expect(m.phy == "coded")
        #expect(m.loc?.vspeed == nil)
        #expect(m.loc?.speed == 5.0)
        #expect(m.basic_id?.first?.uas_id == "1581F204C68D9A11")
    }
}

@Suite struct CRC32Tests {
    @Test func knownVector() {
        // Standard check value; must match the firmware's esp_rom_crc32_le
        // or every tile transfer would fail its fs_end verification.
        #expect(TileSync.crc32(Data("123456789".utf8)) == 0xCBF43926)
    }

    @Test func empty() {
        #expect(TileSync.crc32(Data()) == 0x0000_0000)
    }
}

@Suite struct TileMathTests {
    @Test func deg2tileReferencePoints() {
        // Constants independently computed with the standard slippy-map formula
        let a = TileSync.deg2tile(lat: 37.7749, lon: -122.4194, z: 15)
        #expect(a.x == 5241 && a.y == 12665)
        let b = TileSync.deg2tile(lat: 37.7749, lon: -122.4194, z: 11)
        #expect(b.x == 327 && b.y == 791)
        let c = TileSync.deg2tile(lat: 37.8039, lon: -122.4640, z: 15)
        #expect(c.x == 5237 && c.y == 12662)
    }
}

@Suite struct MfrLookupTests {
    @Test func knownAndUnknownCodes() {
        #expect(MfrLookup.manufacturer(serial: "1581F204C68D9A11") == "DJI")
        #expect(MfrLookup.manufacturer(serial: "1581e0000000") == "DJI")
        #expect(MfrLookup.manufacturer(serial: "ZZZZ00000000") == nil)
        #expect(MfrLookup.manufacturer(serial: "158") == nil)  // too short
    }
}

@Suite struct SerialStatusTests {
    @Test func labels() {
        #expect(SerialStatus.connected("/dev/cu.usbserial-3110").label
                == "cu.usbserial-3110")
        #expect(!SerialStatus.searching.isConnected)
        #expect(SerialStatus.connected("x").isConnected)
    }
}

@Suite struct TrackConflictTests {
    @Test @MainActor func conflictingUasIdPreservesBothTracks() throws {
        let model = AppModel(startServices: false)
        let lineA = #"{"type":"rid","src":"wifi","mac":"02:00:5E:7E:57:01","basic_id":[{"id_type":1,"ua_type":2,"uas_id":"DRONE-A"}]}"#
        model.ingest(line: lineA)
        #expect(model.tracks["uas:DRONE-A"] != nil)

        let lineB = #"{"type":"rid","src":"wifi","mac":"02:00:5E:7E:57:01","basic_id":[{"id_type":1,"ua_type":2,"uas_id":"DRONE-B"}]}"#
        model.ingest(line: lineB)

        #expect(model.tracks["uas:DRONE-A"] != nil)
        #expect(model.tracks["uas:DRONE-B"] != nil)
    }

    @Test @MainActor func anonymousMacTrackPromotesOnUasId() throws {
        let model = AppModel(startServices: false)
        let lineAnon = #"{"type":"rid","src":"ble","mac":"02:00:5E:7E:57:02","loc":{"status":2,"lat":37.8,"lon":-122.4,"alt_geo":100,"alt_baro":95,"height":50,"height_ref":0,"speed":10,"dir":180,"ts":100}}"#
        model.ingest(line: lineAnon)
        #expect(model.tracks["mac:02:00:5E:7E:57:02"] != nil)

        let lineId = #"{"type":"rid","src":"ble","mac":"02:00:5E:7E:57:02","basic_id":[{"id_type":1,"ua_type":2,"uas_id":"DRONE-C"}]}"#
        model.ingest(line: lineId)
        #expect(model.tracks["mac:02:00:5E:7E:57:02"] == nil)
        #expect(model.tracks["uas:DRONE-C"] != nil)
        #expect(model.tracks["uas:DRONE-C"]?.seenLoc == true)
    }
}

@Suite struct TileSyncTests {
    @Test @MainActor func tileSyncCancelResetsState() {
        let ts = TileSync()
        ts.cancel()
        #expect(!ts.running)
    }

    @Test @MainActor func strayRepliesWhileIdleAreIgnored() throws {
        // Acks and completions left over from an interrupted session must
        // not start, advance or fail a sync that is not running.
        let ts = TileSync()
        for line in [#"{"type":"ack","q":3}"#,
                     #"{"type":"fs_ok","p":"/tiles/1/2/3.png"}"#,
                     #"{"type":"fs_ls_done","n":0}"#,
                     #"{"type":"fs_err","msg":"crc"}"#] {
            ts.handle(try decode(line))
        }
        #expect(ts.phase == .idle)
        #expect(!ts.running)
    }
}

@Suite struct ReceiverHealthTests {
    @Test func derivation() {
        let now = Date()
        let port = SerialStatus.connected("/dev/cu.usbmodem1")
        #expect(AppModel.receiverHealth(serial: .searching, lastHeartbeat: nil, now: now)
                == .searching)
        // Without a port an old heartbeat vouches for nothing.
        #expect(AppModel.receiverHealth(serial: .searching, lastHeartbeat: now, now: now)
                == .searching)
        #expect(AppModel.receiverHealth(serial: .failed("x"), lastHeartbeat: nil, now: now)
                == .searching)
        #expect(AppModel.receiverHealth(serial: port, lastHeartbeat: nil, now: now)
                == .waitingForData)
        #expect(AppModel.receiverHealth(serial: port, lastHeartbeat: now.addingTimeInterval(-2),
                                        now: now) == .receiving)
        #expect(AppModel.receiverHealth(serial: port, lastHeartbeat: now.addingTimeInterval(-10),
                                        now: now) == .stalled)
    }

    @Test @MainActor func everySurfaceReadsTheSameState() throws {
        let model = AppModel(startServices: false)
        #expect(model.receiverHealth == .searching)
        #expect(model.receiverStatusText == "searching for device…")

        model.serialStatus = .connected("/dev/cu.usbmodem1")
        #expect(model.receiverHealth == .waitingForData)
        #expect(model.receiverStatusText == "cu.usbmodem1 · waiting for data")

        model.ingest(line: #"{"type":"hb","up":1000,"rid":0}"#)
        model.now = Date()
        #expect(model.receiverHealth == .receiving)
        #expect(model.receiverStatusText == "cu.usbmodem1")

        model.now = model.now.addingTimeInterval(AppModel.heartbeatTimeout + 4)
        #expect(model.receiverHealth == .stalled)
        #expect(model.receiverStatusText == "cu.usbmodem1 · no heartbeat")

        model.serialStatus = .searching
        #expect(model.receiverHealth == .searching)
    }
}

@Suite struct FreshnessTests {
    @Test @MainActor func oneStalenessPolicyForEverySurface() throws {
        let model = AppModel(startServices: false)
        model.ingest(line: #"{"type":"rid","src":"ble","mac":"02:00:5E:7E:57:10","basic_id":[{"id_type":1,"ua_type":2,"uas_id":"FRESH-1"}]}"#)
        let t = try #require(model.tracks["uas:FRESH-1"])
        // The desktop agrees with the firmware's "active within the last minute".
        #expect(AppModel.staleAfter == 60)
        model.now = t.lastSeen.addingTimeInterval(45)
        #expect(abs(model.age(of: t) - 45) < 0.001)
        #expect(!model.isStale(t))   // 45 s: fresh in the row AND on the map
        model.now = t.lastSeen.addingTimeInterval(75)
        #expect(model.isStale(t))    // 75 s: stale in the row AND on the map
    }
}

@Suite struct HeightReferenceTests {
    @Test @MainActor func heightRefIsKeptAndLabelled() throws {
        let model = AppModel(startServices: false)
        model.ingest(line: #"{"type":"rid","src":"ble","mac":"02:00:5E:7E:57:11","basic_id":[{"id_type":1,"ua_type":2,"uas_id":"H-1"}],"loc":{"status":2,"lat":37.8,"lon":-122.4,"alt_geo":100,"alt_baro":95,"height":50,"height_ref":1,"speed":10,"dir":180,"ts":100}}"#)
        let agl = try #require(model.tracks["uas:H-1"])
        #expect(agl.heightRef == 1)
        #expect(agl.heightLabel == "HEIGHT AGL")
        #expect(agl.heightRefShort == "AGL")

        model.ingest(line: #"{"type":"rid","src":"ble","mac":"02:00:5E:7E:57:12","basic_id":[{"id_type":1,"ua_type":2,"uas_id":"H-2"}],"loc":{"status":2,"lat":37.8,"lon":-122.4,"alt_geo":100,"alt_baro":95,"height":50,"height_ref":0,"speed":10,"dir":180,"ts":100}}"#)
        #expect(model.tracks["uas:H-2"]?.heightRef == 0)
        #expect(model.tracks["uas:H-2"]?.heightLabel == "HEIGHT ABOVE T/O")

        model.ingest(line: #"{"type":"rid","src":"ble","mac":"02:00:5E:7E:57:13","basic_id":[{"id_type":1,"ua_type":2,"uas_id":"H-3"}]}"#)
        #expect(model.tracks["uas:H-3"]?.heightRef == nil)
        #expect(model.tracks["uas:H-3"]?.heightLabel == "REPORTED HEIGHT")
        #expect(model.tracks["uas:H-3"]?.heightRefShort == nil)
    }
}

@Suite struct AlertWordingTests {
    @Test func emergencyAndInvalidSignatureNeverCollapseToOneWord() {
        #expect(RidNames.status(3) == "Emergency reported")
        #expect(RidNames.authLabel("invalid") == "ID signature INVALID")
        #expect(TrackAlert.emergency.label == "EMERGENCY REPORTED")
        #expect(TrackAlert.authInvalid.label == "ID SIGNATURE INVALID")
        #expect(TrackAlert.simulated.label == "SIMULATED")
        #expect(TrackAlert.emergency.symbol != TrackAlert.authInvalid.symbol)
    }

    @Test @MainActor func alertsAndBadgesFromIngestedState() throws {
        let model = AppModel(startServices: false)
        model.ingest(line: #"{"type":"rid","src":"ble","mac":"02:00:5E:7E:57:20","basic_id":[{"id_type":1,"ua_type":2,"uas_id":"ALERT-1"}],"loc":{"status":3,"lat":37.8,"lon":-122.4,"alt_geo":100,"alt_baro":95,"height":50,"height_ref":1,"speed":10,"dir":180,"ts":100},"auth":{"type":1,"len":32,"pages":1,"state":"invalid"}}"#)
        let t = try #require(model.tracks["uas:ALERT-1"])
        #expect(t.isEmergency && t.isAuthInvalid && t.isAlerting)
        #expect(t.alerts == [.emergency, .authInvalid])

        // Simulation is a badge, not an alert.
        model.ingest(RidMessage(type: "rid", src: "ble", mac: "DE:M0:00:00:00:99",
                                basic_id: [BasicId(id_type: 1, ua_type: 2, uas_id: "DEMO-9")]),
                     demo: true)
        let d = try #require(model.tracks["uas:DEMO-9"])
        #expect(d.alerts == [.simulated])
        #expect(!d.isAlerting)
        #expect(model.simulatedCount == 1)
        #expect(model.droneCountHeader == "Drones — 2 (1 simulated)")
    }
}

@Suite struct HeaderStringTests {
    @Test func countsAndBanner() {
        #expect(AppModel.droneCountHeader(total: 0, simulated: 0) == "Drones — 0")
        #expect(AppModel.droneCountHeader(total: 3, simulated: 0) == "Drones — 3")
        #expect(AppModel.droneCountHeader(total: 3, simulated: 2)
                == "Drones — 3 (2 simulated)")
        #expect(AppModel.simulationBanner(count: 2)
                == "SIMULATION ACTIVE — 2 simulated aircraft")
    }
}

@Suite struct CardExclusivityTests {
    @Test @MainActor func pickingOneCardClosesTheOther() {
        let model = AppModel(startServices: false)
        model.selection = "uas:X"
        model.selectedTFR = "tfr-1"
        #expect(model.selection == nil)
        #expect(model.selectedTFR == "tfr-1")
        model.selection = "uas:Y"
        #expect(model.selectedTFR == nil)
        #expect(model.selection == "uas:Y")
        model.selection = nil   // clearing never touches the other card
        #expect(model.selectedTFR == nil)
    }
}

@Suite struct MapLabelTests {
    private typealias P = (id: String, point: CGPoint, priority: Int, width: CGFloat)
    private func pt(_ id: String, _ x: CGFloat, _ y: CGFloat, _ pri: Int,
                    _ w: CGFloat = 100) -> P {
        (id, CGPoint(x: x, y: y), pri, w)
    }

    @Test func overlappingLabelsKeepTheHigherPriority() {
        // Labels overlap by 10 pt; neither marker is under the other's label.
        let same = MapLabels.visibleLabels(points: [
            pt("a", 100, 100, MapLabels.fresh), pt("b", 190, 100, MapLabels.fresh)])
        #expect(same == ["a"])   // equal priority: first in input order wins
        let mixed = MapLabels.visibleLabels(points: [
            pt("a", 100, 100, MapLabels.stale), pt("b", 190, 100, MapLabels.fresh)])
        #expect(mixed == ["b"])
    }

    @Test func selectedAndAlertingAlwaysShow() {
        let vis = MapLabels.visibleLabels(points: [
            pt("plain", 120, 104, MapLabels.fresh),
            pt("alert", 110, 102, MapLabels.alerting),
            pt("sel", 100, 100, MapLabels.selected)])
        #expect(vis == ["sel", "alert"])
    }

    @Test func farApartAllShow() {
        let vis = MapLabels.visibleLabels(points: [
            pt("a", 100, 100, MapLabels.fresh), pt("b", 400, 100, MapLabels.fresh),
            pt("c", 100, 400, MapLabels.stale)])
        #expect(vis == ["a", "b", "c"])
    }

    @Test func labelNeverCoversAnotherMarker() {
        // b's marker sits exactly where a's label would be drawn.
        let vis = MapLabels.visibleLabels(points: [
            pt("a", 100, 100, MapLabels.fresh), pt("b", 100, 130, MapLabels.fresh)])
        #expect(vis == ["b"])
    }
}

@Suite struct MapFitTests {
    @Test func fittedContentClearsTheCardAndStrip() {
        let content = MKMapRect(x: 1000, y: 1000, width: 200, height: 100)
        let frame = CGSize(width: 800, height: 600)
        let insets = MapFit.Insets(top: 0, left: 344, bottom: 44, right: 0)
        let r = MapFit.rect(content: content, frame: frame, insets: insets)
        // Same aspect as the pane.
        #expect(abs(r.width / r.height - frame.width / frame.height) < 1e-9)
        // Projected to pane points, the content lies right of the card,
        // above the strip, and centred in what is left.
        let scale = r.width / frame.width
        let leftPx = (content.minX - r.minX) / scale
        let rightPx = (content.maxX - r.minX) / scale
        let bottomPx = (content.maxY - r.minY) / scale
        let cxPx = (content.midX - r.minX) / scale
        #expect(leftPx >= 344 - 1e-6)
        #expect(rightPx <= 800 + 1e-6)
        #expect(bottomPx <= 600 - 44 + 1e-6)
        #expect(abs(cxPx - (344 + (800 - 344) / 2)) < 1e-6)
    }

    @Test func noInsetsCentresContent() {
        let content = MKMapRect(x: 0, y: 0, width: 100, height: 100)
        let r = MapFit.rect(content: content, frame: CGSize(width: 400, height: 400),
                            insets: MapFit.Insets())
        #expect(abs(r.midX - 50) < 1e-9 && abs(r.midY - 50) < 1e-9)
        #expect(abs(r.width - 100) < 1e-9)
    }

    @Test func boundsHonourTheMinimumSpan() {
        let c = CLLocationCoordinate2D(latitude: 37.8, longitude: -122.4)
        let b = MapFit.bounds(of: [c], margin: 1, minMeters: 2000)
        let metres = b.width / MKMapPointsPerMeterAtLatitude(37.8)
        #expect(abs(metres - 2000) < 1)
        #expect(abs(MKMapPoint(c).x - b.midX) < 1e-6)
        #expect(MapFit.bounds(of: [], margin: 1, minMeters: 1).isNull)
    }
}

@Suite struct UasModelTests {
    @Test func modelAndMakeFromSerial() {
        #expect(UasModels.model(serial: "1581F6Z9ABCDEFGH") == "DJI Mini 4 Pro")
        #expect(UasModels.model(serial: "1581f6z9abcdefgh") == "DJI Mini 4 Pro")
        #expect(UasModels.model(serial: "1581FZZZ00000000") == nil)
        #expect(UasModels.model(serial: "1581F6") == nil)   // too short
        #expect(UasModels.manufacturer(serial: "1581F6Z9ABCDEFGH") == "DJI")
    }
}

@Suite struct CoordinateSanityTests {
    @Test func nearZeroSentinelsAreNotPositions() {
        #expect(!AppModel.validCoord(0, 0))
        #expect(!AppModel.validCoord(0.0000001, -0.0000001))
        #expect(!AppModel.validCoord(3.2, 4.9))
        #expect(AppModel.validCoord(37.8, -122.4))
        #expect(AppModel.validCoord(5.6, -0.2))   // Accra is a real place
        #expect(!AppModel.validCoord(91, 0))
    }

    @Test @MainActor func implausibleJumpRestartsTheTrail() throws {
        let model = AppModel(startServices: false)
        func loc(_ lat: Double, _ lon: Double) -> String {
            #"{"type":"rid","src":"wifi","mac":"02:00:5E:7E:57:11","basic_id":[{"id_type":1,"ua_type":2,"uas_id":"JUMP-1"}],"loc":{"status":2,"lat":\#(lat),"lon":\#(lon),"alt_geo":100,"alt_baro":95,"height":50,"height_ref":0,"speed":10,"dir":180,"ts":100}}"#
        }
        model.ingest(line: loc(37.8000, -122.4000))
        model.ingest(line: loc(37.8010, -122.4000))
        #expect(model.tracks["uas:JUMP-1"]?.trail.count == 2)
        model.ingest(line: loc(38.5000, -122.4000))   // ~78 km in one broadcast
        #expect(model.tracks["uas:JUMP-1"]?.trail.count == 1)
        #expect(model.tracks["uas:JUMP-1"]?.coordinate?.latitude == 38.5)
    }

    @Test func stepAllowanceScalesWithSilence() {
        let a = CLLocationCoordinate2D(latitude: 37.8000, longitude: -122.4000)
        let b = CLLocationCoordinate2D(latitude: 37.8270, longitude: -122.4000)   // ~3 km
        #expect(!AppModel.plausibleStep(a, b, elapsed: 1))     // 3 km in a second is a teleport
        #expect(AppModel.plausibleStep(a, b, elapsed: 60))     // 3 km in a minute is a fast aircraft
        #expect(AppModel.stepAllowance(elapsed: 0) < 1_000)
        #expect(AppModel.stepAllowance(elapsed: -5) == AppModel.stepAllowance(elapsed: 0))
    }
}

@Suite struct FormatAndSsidTests {
    @Test @MainActor func formatSsidModelAndMismatchAreKept() throws {
        let model = AppModel(startServices: false)
        model.ingest(line: #"{"type":"rid","src":"wifi","mac":"8C:1E:D9:03:09:B2","fmt":"gb46750","ssid":"RID-1581FANLC258U029RTN6","ssid_id_match":true,"basic_id":[{"id_type":1,"ua_type":0,"uas_id":"1581FANLC258U029RTN6"}]}"#)
        let t = try #require(model.tracks["uas:1581FANLC258U029RTN6"])
        #expect(t.format == "GB 46750-2025")
        #expect(t.ssid == "RID-1581FANLC258U029RTN6")
        #expect(!t.ssidMismatch)
        #expect(t.model == "DJI Mini 5 Pro (enhanced transmission)")
        model.ingest(line: #"{"type":"rid","src":"wifi","mac":"8C:1E:D9:03:09:B3","proto":1,"ssid":"RID-1581F8DBW25B800B3417","ssid_id_match":false,"basic_id":[{"id_type":1,"ua_type":2,"uas_id":"1581F8DBW25B800B3499"}]}"#)
        let u = try #require(model.tracks["uas:1581F8DBW25B800B3499"])
        #expect(u.format == "ASTM F3411 v1")
        #expect(u.ssidMismatch)
        #expect(u.model == "DJI Matrice 400")
    }
}

@Suite struct SetTimeCommandTests {
    @Test func wholeUtcSecondsInTheFirmwaresShape() throws {
        // The T5 parses "utc" with strtod and casts to time_t, and the flash
        // script sends the same line: whole seconds, no fraction, no quotes.
        let when = Date(timeIntervalSince1970: 1_790_101_127.9)
        let line = AppModel.setTimeCommand(now: when)
        #expect(line == #"{"cmd":"set_time","utc":1790101127}"#)
        let obj = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(obj["cmd"] as? String == "set_time")
        #expect(obj["utc"] as? Int == 1_790_101_127)
    }
}
