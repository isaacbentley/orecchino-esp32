import Foundation
import CoreLocation

/// Synthesizes two moving drones so the UI can be exercised with no hardware
/// (and no drone in the air). Injected through the same ingest path as the
/// serial feed.
@MainActor
final class DemoFeed {
    private var timer: Timer?
    private var angle = 0.0

    // Crissy Field, San Francisco
    private let center = (lat: 37.8039, lon: -122.4640)

    func start(model: AppModel) {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.tick(AppModel.shared) }
            }
        }
        tick(model)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick(_ model: AppModel) {
        angle += 0.02
        let mPerDegLat = 111_111.0
        let mPerDegLon = mPerDegLat * cos(center.lat * .pi / 180)

        // Drone 1: 400 m orbit
        let r1 = 400.0
        let d1 = (lat: center.lat + r1 * sin(angle) / mPerDegLat,
                  lon: center.lon + r1 * cos(angle) / mPerDegLon)
        let h1 = (90 - (angle * 180 / .pi + 90)).truncatingRemainder(dividingBy: 360)
        model.ingest(RidMessage(
            type: "rid", src: "ble", mac: "DE:M0:00:00:00:01", rssi: -58 - Int.random(in: 0...6),
            basic_id: [BasicId(id_type: 1, ua_type: 2, uas_id: "1581F-DEMO-ALPHA")],
            loc: Loc(status: 2, lat: d1.lat, lon: d1.lon, alt_geo: 82, alt_baro: 80,
                     height: 60, height_ref: 0, speed: 8.0, vspeed: 0,
                     dir: h1 < 0 ? h1 + 360 : h1, ts: 0),
            self_id: SelfId(desc_type: 0, desc: "Demo survey flight"),
            system: SystemMsg(op_lat: center.lat, op_lon: center.lon, op_alt: 12,
                              op_loc_type: 1, area_count: 1, ts: 0),
            op_id: OpId(id_type: 0, id: "FIN87astrdge12k8-demo")
        ), demo: true)

        // Drone 2: slow figure-eight to the east
        let r2 = 250.0
        let d2 = (lat: center.lat + 0.004 + r2 * sin(2 * angle) / mPerDegLat / 2,
                  lon: center.lon + 0.012 + r2 * sin(angle) / mPerDegLon)
        model.ingest(RidMessage(
            type: "rid", src: "wifi", mac: "DE:M0:00:00:00:02", rssi: -74 - Int.random(in: 0...8),
            ch: 6,
            basic_id: [BasicId(id_type: 1, ua_type: 2, uas_id: "1581F-DEMO-BRAVO")],
            loc: Loc(status: 2, lat: d2.lat, lon: d2.lon, alt_geo: 45, alt_baro: 44,
                     height: 30, height_ref: 0, speed: 4.2, vspeed: 0.5, dir: 90, ts: 0)
        ), demo: true)

        // Traffic 1: UAL123 passing the survey drone area. alt_geom is
        // WGS-84 like the drones' alt_geo (plan §8.2).
        let nowMs = TrafficRules.nowMs()
        let t1Dist = 1800.0 - 400.0 * sin(angle * 0.5)
        let t1 = (lat: center.lat + t1Dist * cos(1.2) / mPerDegLat,
                  lon: center.lon + t1Dist * sin(1.2) / mPerDegLon)
        let contact1 = TrafficAircraft(
            hex: "a1b2c3", callsign: "UAL123", type: "B738",
            lat: t1.lat, lon: t1.lon,
            altGeomM: 130.0, altBaroM: 808.0,          // ~2,650 ft pressure altitude
            gsMps: 180.0 * TrafficRules.ktToMps, trackDeg: 245.0,
            vsMps: -640.0 * TrafficRules.ftToM / 60.0,
            squawk: 1200, seenMs: nowMs - 2000)

        // Traffic 2: SWA4211 transit higher up
        let t2 = (lat: center.lat + 0.035, lon: center.lon - 0.025)
        let contact2 = TrafficAircraft(
            hex: "a4d5e6", callsign: "SWA4211", type: "B737",
            lat: t2.lat, lon: t2.lon,
            altGeomM: 3380.0, altBaroM: 3352.0,        // ~11,000 ft
            gsMps: 290.0 * TrafficRules.ktToMps, trackDeg: 70.0, vsMps: 0,
            squawk: 3421, seenMs: nowMs - 4000)

        model.traffic.updateAircraft([contact1, contact2], dataMs: nowMs - 2000)
    }
}
