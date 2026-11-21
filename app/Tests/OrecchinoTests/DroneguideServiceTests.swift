// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import Orecchino

@Suite struct DroneguideServiceTests {
    @Test func wfsWindowContainsEscapedUTCMilliseconds() throws {
        let start = try #require(DroneguideData.date("2026-11-18T10:12:00Z"))
        let url = DroneguideWFS.requestURL(start: start, index: 40)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = try #require(components.queryItems)
        #expect(url.host == "map.droneguide.be")
        #expect(query.first { $0.name == "startIndex" }?.value == "40")
        #expect(query.first { $0.name == "cql_filter" }?.value == DroneguideData.altitudeCQL)
        #expect(query.first { $0.name == "viewParams" }?.value ==
                #"window_start:2026-11-18T10\:12\:00.000Z;window_end:2026-11-19T10\:12\:00.000Z;show_planned:true"#)
    }

    @MainActor @Test func persistedImportAndActiveFilterUseCurrentClock() async throws {
        let name = "DroneguideTests-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let defaults = try #require(UserDefaults(suiteName: name))
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
        let file = directory.appendingPathComponent("zones.geojson")
        let cache = directory.appendingPathComponent("cache.json")
        let input = #"""
        {"type":"Feature","id":"zone","properties":{"restriction":"PROHIBITED","lower_limit_reference":"GND","validFrom":"2026-11-18T10:00:00Z","validUntil":"2026-11-18T11:00:00Z"},"geometry":{"type":"Polygon","coordinates":[[[4.3,50.8],[4.4,50.8],[4.35,50.86]]]}}
        """#
        try Data(input.utf8).write(to: file)
        let service = DroneguideService(cacheURL: cache, defaults: defaults)
        #expect(!service.liveEnabled && !service.activeOnly)
        await service.importFile(file)
        #expect(service.actionError == nil)
        service.activeOnly = true
        service.showLayer = false

        let restarted = DroneguideService(cacheURL: cache, defaults: defaults)
        restarted.start()
        #expect(restarted.source == .imported && !restarted.liveEnabled)
        #expect(restarted.activeOnly && !restarted.showLayer)
        let zone = try #require(restarted.zones.first)
        let valid = try #require(DroneguideData.date("2026-11-18T10:30:00Z"))
        let ended = try #require(DroneguideData.date("2026-11-18T11:00:00Z"))
        #expect(restarted.includes(zone, at: valid))
        #expect(!restarted.includes(zone, at: ended))
    }
}
