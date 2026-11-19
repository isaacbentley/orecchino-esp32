// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import Orecchino

@Suite struct DroneguideDataTests {
    private let polygon = #"{"type":"Polygon","coordinates":[[[4.3,50.8],[4.4,50.8],[4.35,50.86]]]}"#

    @Test func nativeSnapshotRetainsHolesAndWindowStates() throws {
        let geometry = #"""
        {"type":"GeometryCollection","geometries":[
          {"type":"LineString","coordinates":[[4.3,50.8],[4.4,50.8]]},
          {"type":"Polygon","coordinates":[
            [[4.3,50.8],[4.4,50.8],[4.4,50.86],[4.3,50.86],[4.3,50.8]],
            [[4.33,50.82],[4.34,50.82],[4.34,50.83],[4.33,50.82]]
          ]}
        ]}
        """#
        let input = #"""
        {"type":"FeatureCollection","features":[
          {"type":"Feature","id":"active","properties":{"restriction":"PROHIBITED","name":"{\"fr\":\"Zone belge\",\"nl\":\"Proefzone\"}","active_at_window_start":0,"active_within_window":0,"lower_limit_altitude_meter_agl":0},"geometry":\#(geometry)},
          {"type":"Feature","id":"planned","properties":{"restriction":"CONDITIONAL","active_at_window_start":1,"active_within_window":0,"lower_limit_altitude_meter_agl":0},"geometry":\#(polygon)},
          {"type":"Feature","id":"inactive","properties":{"restriction":"REQ_AUTHORISATION","active_at_window_start":1,"active_within_window":1,"lower_limit_altitude_meter_agl":0},"geometry":\#(polygon)}
        ]}
        """#
        let live = try DroneguideData.parse(Data(input.utf8), live: true)
        #expect(live.zones.map(\.activity) == [.active, .planned, .inactive])
        let zone = try #require(live.zones.first)
        #expect(zone.name == "Proefzone")
        #expect(zone.polygons[0].count == 2)
        #expect(zone.polygons[0][0][0] == DroneguidePoint(latitude: 50.8, longitude: 4.3))
        let manual = try DroneguideData.parse(Data(input.utf8))
        #expect(manual.zones.map { $0.activity(at: Date()) } == [.unknown, .unknown, .unknown])
    }

    @Test func appliesAltitudeBandToEachVolumeAndKeepsBoundary() throws {
        let input = #"""
        {"identifier":"BEDEMO","country":"BEL","restriction":"CONDITIONAL","geometry":[
          {"lowerLimit":500,"upperLimit":550,"uomDimensions":"FT","lowerVerticalReference":"AGL","upperVerticalReference":"AGL","horizontalProjection":\#(polygon)},
          {"lowerLimit":152.40001,"upperLimit":270,"uomDimensions":"M","lowerVerticalReference":"AGL","upperVerticalReference":"AGL","horizontalProjection":\#(polygon)},
          {"lowerLimit":-20,"upperLimit":0,"uomDimensions":"M","lowerVerticalReference":"GND","upperVerticalReference":"GND","horizontalProjection":\#(polygon)},
          {"lowerLimit":50,"upperLimit":300,"uomDimensions":"M","lowerVerticalReference":"AMSL","upperVerticalReference":"AMSL","horizontalProjection":\#(polygon)}
        ]}
        """#
        let parsed = try DroneguideData.parse(Data(input.utf8))
        #expect(parsed.zones.map(\.id) == ["BEDEMO", "BEDEMO#3"])
        #expect(parsed.unknownAltitudeCount == 1)
        #expect(parsed.omittedGeometryCount == 0)
        #expect(parsed.zones[0].lower == 500)
        #expect(parsed.zones[0].polygons[0][0].count == 4)
    }

    @Test func prefersGroundLimitsAndOmitsConflictingConversions() throws {
        let input = #"""
        {"type":"FeatureCollection","features":[
          {"type":"Feature","id":"ground","properties":{"restriction":"PROHIBITED","lower_limit_altitude":500,"lower_limit_reference":"GND","lower_limit_unit":"F","lower_limit_altitude_meter_agl":999,"upper_limit_altitude_meter_agl":350},"geometry":\#(polygon)},
          {"type":"Feature","id":"only-upper","properties":{"restriction":"PROHIBITED","upper_limit_altitude_meter_agl":152.4},"geometry":\#(polygon)},
          {"type":"Feature","id":"conflicting","properties":{"restriction":"PROHIBITED","lower_limit_altitude_meter_agl":45720,"upper_limit_altitude_meter_agl":5943.6},"geometry":\#(polygon)},
          {"type":"Feature","id":"point","properties":{"restriction":"PROHIBITED","lower_limit_altitude_meter_agl":0},"geometry":{"type":"Point","coordinates":[4.5,50.5]}}
        ]}
        """#
        let parsed = try DroneguideData.parse(Data(input.utf8), live: true)
        #expect(parsed.zones.map(\.id) == ["ground", "only-upper"])
        #expect(parsed.unknownAltitudeCount == 1)
        #expect(parsed.omittedGeometryCount == 1)
    }

    @Test func checksOvernightScheduleAgainstItsStartDay() throws {
        let input = #"""
        {"identifier":"BEDEMO","country":"BE","restriction":"CONDITIONAL",
         "applicability":[{"permanent":"YES","schedule":[{"day":["MON"],"startTime":"22:00:00+01:00","endTime":"03:00:00+01:00"}]}],
         "geometry":[{"lowerVerticalReference":"GND","horizontalProjection":{"type":"Circle","center":[4.345,50.82],"radius":3000}}]}
        """#
        let parsed = try DroneguideData.parse(Data(input.utf8))
        let zone = try #require(parsed.zones.first)
        let ring = zone.polygons[0][0]
        #expect(zone.circle?.radiusMeters == 3000)
        #expect(ring.count >= 97 && ring.first == ring.last)
        #expect((50.846...50.848).contains(ring[0].latitude))
        let mondayStart = try #require(DroneguideData.date("2026-11-16T21:00:00Z"))
        let tuesdayWithin = try #require(DroneguideData.date("2026-11-17T01:30:00Z"))
        let tuesdayEnd = try #require(DroneguideData.date("2026-11-17T02:00:00Z"))
        let tuesdayEvening = try #require(DroneguideData.date("2026-11-17T21:00:00Z"))
        #expect(zone.activity(at: mondayStart) == .active)
        #expect(zone.activity(at: tuesdayWithin) == .active)
        #expect(zone.activity(at: tuesdayEnd) == .inactive)
        #expect(zone.activity(at: tuesdayEvening) == .inactive)
    }

    @Test func importWithoutCompleteOrInterpretableTimingRemainsUnknown() throws {
        let input = #"""
        {"type":"Feature","id":42,"properties":{"restriction":"PROHIBITED","lower_limit_reference":"GND","validFrom":"2026-11-01T00:00:00Z","validUntil":"2026-12-01T00:00:00Z","schedule":"On call"},"geometry":\#(polygon)}
        """#
        let parsed = try DroneguideData.parse(Data(input.utf8))
        let zone = try #require(parsed.zones.first)
        let within = try #require(DroneguideData.date("2026-11-16T21:00:00Z"))
        let after = try #require(DroneguideData.date("2026-12-01T00:00:00Z"))
        #expect(zone.id == "42")
        #expect(zone.activity(at: within) == .unknown)
        #expect(zone.activity(at: after) == .inactive)
        let untimed = input.replacingOccurrences(of: ",\"schedule\":\"On call\"", with: "")
        let timedZone = try #require(DroneguideData.parse(Data(untimed.utf8)).zones.first)
        #expect(timedZone.activity(at: within) == .active)
    }
}
