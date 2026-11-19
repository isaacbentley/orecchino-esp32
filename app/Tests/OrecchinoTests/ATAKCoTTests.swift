// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import Testing
@testable import Orecchino

@Suite struct ATAKCoTTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func sample(_ sequence: Int = 1, offset: TimeInterval = 0,
                        latitude: Double = 50.865, longitude: Double = 4.435,
                        hae: Double? = nil) -> ATAKSample {
        ATAKSample(sequence: sequence, fix: ATAKFix(
            observedAt: t0.addingTimeInterval(offset), latitude: latitude,
            longitude: longitude, hae: hae
        ))
    }

    @Test func eventUsesOneValidCoTDocumentWithAnOpaqueContactAndARealFix() throws {
        let data = try #require(ATAKCoT.event(sample(3, hae: 83.2), session: "abc&\"<",
                                              at: t0.addingTimeInterval(1)))
        let elements = try decode(data)
        let event = try #require(elements["event"])
        #expect(event["version"] == "2.0")
        #expect(event["uid"] == "orecchino-rid-abc&\"<-3")
        #expect(event["type"] == "a-u-A")
        #expect(event["how"] == "m-r")
        #expect(event["access"] == "Undefined")
        #expect(event["time"] == "2023-11-14T22:13:20.000Z")
        #expect(event["start"] == event["time"])
        #expect(event["stale"] == "2023-11-14T22:14:20.000Z")
        #expect(elements["point"] == [
            "lat": "50.8650000", "lon": "4.4350000", "hae": "83.2",
            "ce": "9999999.0", "le": "9999999.0",
        ])
        #expect(elements["contact"] == ["callsign": "Orecchino UAS 3"])
    }

    @Test func invalidAndExpiredPositionsAreExcludedAndUnknownHAEUsesSentinel() throws {
        #expect(ATAKCoT.event(sample(latitude: 0, longitude: 0), session: "abc", at: t0) == nil)
        #expect(ATAKCoT.event(sample(latitude: 91), session: "abc", at: t0) == nil)
        #expect(ATAKCoT.event(sample(longitude: .infinity), session: "abc", at: t0) == nil)
        #expect(ATAKCoT.event(sample(offset: 1), session: "abc", at: t0) == nil)
        #expect(ATAKCoT.event(sample(), session: "abc", at: t0.addingTimeInterval(60)) == nil)
        for altitude in [nil, -1000, .infinity, 1e308] as [Double?] {
            let data = try #require(ATAKCoT.event(sample(hae: altitude), session: "abc", at: t0))
            let decoded = try decode(data)
            #expect(decoded["point"]?["hae"] == "9999999.0")
        }
    }

    @Test func planBoundsBatchesAndRateLimitsNewFixesWithoutRepeatingSuccessfulOnes() {
        var plan = ATAKSendPlan()
        let contacts = (1...10).map { sample($0) }
        let first = plan.batch(contacts, at: t0)
        #expect(first.map(\.sequence) == Array(1...8))
        for item in first { plan.sent(item) }
        #expect(plan.batch(contacts, at: t0.addingTimeInterval(0.5)).map(\.sequence) == [9, 10])
        // An unsuccessful attempt can retry after its throttle interval.
        #expect(plan.batch(contacts, at: t0.addingTimeInterval(2)).isEmpty)
        let retry = plan.batch(contacts, at: t0.addingTimeInterval(2.5))
        #expect(retry.map(\.sequence) == [9, 10])
        for item in retry { plan.sent(item) }
        let newer = [sample(1, offset: 1)]
        #expect(plan.batch(newer, at: t0.addingTimeInterval(3)).map(\.sequence) == [1])
        let latest = [sample(1, offset: 3.5)]
        #expect(plan.batch(latest, at: t0.addingTimeInterval(4)).isEmpty)
        #expect(plan.batch(latest, at: t0.addingTimeInterval(5)).map(\.sequence) == [1])
        #expect(plan.batch(latest, at: t0.addingTimeInterval(64)).isEmpty)
    }

    @Test func directDestinationValidatesHostAndPort() throws {
        let local = try ATAKEndpoint(host: " 127.0.0.1 ", port: ATAKEndpoint.defaultPort)
        #expect(local.display == "127.0.0.1:4242")
        #expect(try local.resolve() == "127.0.0.1")
        let ipv6 = try ATAKEndpoint(host: "[::1]", port: 4242)
        #expect(ipv6.display == "[::1]:4242")
        let host = try ATAKEndpoint(host: "ATAK.local", port: 4242)
        #expect(host.host == "atak.local")
        for invalid in ["", "https://example.com", "phone.local:4242", "bad host", "999.1.1.1",
                        "239.2.3.1", "255.255.255.255", "0.0.0.0", "[ff02::1]", "::", "::ffff:239.2.3.1"] {
            #expect(throws: ATAKError.self) { try ATAKEndpoint(host: invalid, port: 4242) }
        }
        #expect(throws: ATAKError.self) { try ATAKEndpoint(host: "127.0.0.1", port: 0) }
        #expect(throws: ATAKError.self) { try ATAKEndpoint(host: "127.0.0.1", port: 65536) }
    }

    @MainActor @Test func preferencesDefaultOffAndRestoreOnlyValidatedDestinations() throws {
        let suite = "ATAKTest-\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let service = ATAKService(defaults: preferences)
        #expect(!service.enabled && service.endpoint == nil)
        service.setEnabled(true)
        #expect(!service.enabled && service.settingsError != nil)
        service.saveDestination(host: "127.0.0.1", port: "4242")
        #expect(service.settingsError == nil)
        #expect(!service.enabled)
        service.setEnabled(true)
        #expect(service.enabled && service.lastSent == nil)
        service.saveDestination(host: "239.2.3.1", port: "4242")
        #expect(service.settingsError != nil && service.endpoint?.host == "127.0.0.1")
        let restored = ATAKService(defaults: preferences)
        #expect(restored.enabled && restored.endpoint?.display == "127.0.0.1:4242")
        restored.setEnabled(false)
        #expect(!ATAKService(defaults: preferences).enabled)
    }

    @MainActor @Test func trackPromotionKeepsValidFixAndSimulationHasNone() throws {
        let model = AppModel(startServices: false)
        let real = "AA:BB:CC:DD:EE:FF"
        let valid = Loc(status: 2, lat: 50.865, lon: 4.435, alt_geo: 80,
                        alt_baro: 200, height: 40, height_ref: 1, speed: 10, dir: 180, ts: 0)
        let invalid = Loc(status: 2, lat: 0, lon: 0, alt_geo: 777,
                          alt_baro: 200, height: 40, height_ref: 1, speed: 10, dir: 180, ts: 1)
        model.ingest(RidMessage(type: "rid", mac: real, loc: valid))
        let initial = try #require(model.tracks["mac:\(real)"])
        let fix = try #require(initial.atakFix)
        #expect(fix.hae == 80)
        let basic = BasicId(id_type: 1, ua_type: 2, uas_id: "sample-id")
        model.ingest(RidMessage(type: "rid", mac: real, basic_id: [basic], loc: invalid))
        let promoted = try #require(model.tracks["uas:sample-id"])
        #expect(promoted.colorIndex == initial.colorIndex)
        #expect(promoted.atakFix == fix)
        model.ingest(RidMessage(type: "rid", mac: "DE:00:00:00:00:01", loc: valid), demo: true)
        #expect(model.tracks["mac:DE:00:00:00:00:01"]?.atakFix == nil)
    }

    private func decode(_ data: Data) throws -> [String: [String: String]] {
        let parser = XMLParser(data: data)
        let parsed = CoTDocument()
        parser.delegate = parsed
        #expect(parser.parse())
        return parsed.elements
    }
}

private final class CoTDocument: NSObject, XMLParserDelegate {
    var elements: [String: [String: String]] = [:]

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        elements[name] = attributes
    }
}
