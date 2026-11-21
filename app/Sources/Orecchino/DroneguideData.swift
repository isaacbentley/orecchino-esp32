// SPDX-License-Identifier: GPL-3.0-or-later

import CoreFoundation
import Foundation

struct DroneguidePoint: Hashable, Sendable {
    let latitude: Double
    let longitude: Double
}

struct DroneguideCircle: Sendable {
    let center: DroneguidePoint
    let radiusMeters: Double
}

enum DroneguideActivity: Hashable, Sendable {
    case active, planned, inactive, unknown
}

struct DroneguideZone: Identifiable, Sendable {
    var id: String
    let name: String
    let restriction: String
    let reason: String
    let message: String
    let schedule: String
    var polygons: [[[DroneguidePoint]]] = []
    var circle: DroneguideCircle? = nil
    var lower: Double? = nil
    var upper: Double? = nil
    var lowerReference = ""
    var upperReference = ""
    var lowerUnit = ""
    var upperUnit = ""
    let validFrom: Date?
    let validUntil: Date?
    let authorities: [String]
    let conditions: [String]
    let activity: DroneguideActivity
    fileprivate let liveSnapshot: Bool
    fileprivate let applicability: [DroneguidePeriod]
    fileprivate let freeTextSchedule: Bool
    fileprivate var lowerAGL: Double? = nil
    fileprivate var upperAGL: Double? = nil

    func activity(at now: Date) -> DroneguideActivity {
        if liveSnapshot { return activity }
        if !applicability.isEmpty {
            return DroneguidePeriod.any(applicability.map { $0.activity(at: now) })
        }
        let dates = DroneguidePeriod.dateActivity(from: validFrom, until: validUntil, permanent: false, at: now)
        return dates == .active && freeTextSchedule ? .unknown : dates
    }
}

struct DroneguideParsed: Sendable {
    let zones: [DroneguideZone]
    let omittedGeometryCount: Int
    let unknownAltitudeCount: Int
}

enum DroneguideData {
    static let maxJSONBytes = 12 * 1024 * 1024
    static let maxFeatures = 10_000
    private static let maxPoints = 500_000
    private static let metersPerFoot = 0.3048
    private static let ceilingMeters = 152.4

    // Let the client resolve raw ground-relative limits and doubtful conversions.
    static let altitudeCQL = "type_code <> 'TIME_ZONE' AND (" +
        "lower_limit_altitude_meter_agl IS NULL OR upper_limit_altitude_meter_agl IS NULL OR " +
        "lower_limit_altitude_meter_agl > upper_limit_altitude_meter_agl OR " +
        "((lower_limit_altitude_meter_agl <= 152.4 OR lower_limit_reference IN ('AGL','GND','SFC')) AND " +
        "(upper_limit_altitude_meter_agl >= 0 OR upper_limit_reference IN ('AGL','GND','SFC'))))"

    static func parse(_ data: Data, live: Bool = false) throws -> DroneguideParsed {
        guard data.count <= maxJSONBytes else { throw Failure("The geozone file is too large.") }
        // JSONSerialization can also read UTF-8 with a byte-order mark.
        guard let root = try? JSONSerialization.jsonObject(with: data) else { throw Failure("Invalid geozone JSON.") }
        let features: [Any]
        if let object = root as? JSONObject {
            let type = string(object["type"])
            if live && type != "FeatureCollection" { throw Failure("Droneguide returned no GeoJSON collection.") }
            if type == "Feature" || type == "FeatureCollection" { try checkCRS(object) }
            if type == "Feature" {
                features = [object]
            } else if let items = object["features"] as? [Any] {
                features = items
            } else if object["features"] != nil || type == "FeatureCollection" {
                throw Failure("Invalid geozone collection.")
            } else {
                features = [object]
            }
        } else if let items = root as? [Any], !live {
            features = items
        } else {
            throw Failure("Invalid geozone collection.")
        }
        guard !features.isEmpty, features.count <= maxFeatures else { throw Failure("The file contains no zones or too many zones.") }

        var zones: [DroneguideZone] = []
        var identifiers = Set<String>()
        var points = 0
        var omitted = 0
        var unknown = 0
        for (index, raw) in features.enumerated() {
            do {
                guard let feature = raw as? JSONObject else { throw Failure("Invalid geozone object.") }
                let parsed: [DroneguideZone]
                if live || string(feature["type"]) == "Feature" {
                    parsed = try fromGeoJSON(feature, live: live)
                } else {
                    parsed = try fromED(feature)
                }
                for zone in parsed {
                    guard identifiers.insert(zone.id).inserted else { throw Failure("Duplicate zone code \(zone.id).") }
                    for polygon in zone.polygons { for ring in polygon { points += ring.count } }
                    guard identifiers.count <= maxFeatures, points <= maxPoints else {
                        throw Failure("The file contains too many zones or map points.")
                    }
                    switch band(lower: zone.lowerAGL, upper: zone.upperAGL) {
                    case .inside: zones.append(zone)
                    case .unknown: unknown += 1
                    case .outside: break
                    }
                }
            } catch Failure.noArea where live {
                omitted += 1
            } catch {
                throw Failure("Zone \(index + 1): \(error.localizedDescription)")
            }
        }
        guard !identifiers.isEmpty else { throw Failure("No Belgian zones with mappable geometry were found.") }
        return DroneguideParsed(zones: zones, omittedGeometryCount: omitted, unknownAltitudeCount: unknown)
    }

    static func date(_ value: String) -> Date? {
        let pattern = #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?(?:Z|[+-][0-9]{2}:[0-9]{2})$"#
        guard value.range(of: pattern, options: .regularExpression) != nil else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let result = formatter.date(from: value) { return result }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private enum Band { case inside, outside, unknown }

    private static func band(lower: Double?, upper: Double?) -> Band {
        if let lower, let upper, lower > upper { return .unknown }
        if lower.map({ $0 > ceilingMeters }) == true || upper.map({ $0 < 0 }) == true { return .outside }
        if lower != nil && upper != nil { return .inside }
        if lower.map({ $0 >= 0 }) == true || upper.map({ $0 <= ceilingMeters }) == true { return .inside }
        return .unknown
    }

    private static func groundAltitude(_ value: Double?, reference: String, unit: String) -> Double? {
        let ref = reference.uppercased()
        let surface = ref == "GND" || ref == "SFC"
        guard surface || ref == "AGL" else { return nil }
        guard let value else { return surface ? 0 : nil }
        if unit == "FT" { return value * metersPerFoot }
        if unit == "M" || (unit.isEmpty && value == 0) { return value }
        return nil
    }

    private static func altitude(_ p: JSONObject, for zone: inout DroneguideZone, native: Bool) {
        zone.lower = number(p["lowerLimit"]) ?? number(p["lower_limit_altitude"]) ?? number(p["lower"])
        zone.upper = number(p["upperLimit"]) ?? number(p["upper_limit_altitude"]) ?? number(p["upper"])
        zone.lowerReference = first(string(p["lowerVerticalReference"]), string(p["lower_limit_reference"]), string(p["lowerReference"]))
        zone.upperReference = first(string(p["upperVerticalReference"]), string(p["upper_limit_reference"]), string(p["upperReference"]))
        let commonUnit = first(string(p["uomDimensions"]), string(p["unit"]))
        zone.lowerUnit = unit(first(string(p["lower_limit_unit"]), string(p["lowerUnit"]), commonUnit))
        zone.upperUnit = unit(first(string(p["upper_limit_unit"]), string(p["upperUnit"]), commonUnit))
        zone.lowerAGL = groundAltitude(zone.lower, reference: zone.lowerReference, unit: zone.lowerUnit)
        zone.upperAGL = groundAltitude(zone.upper, reference: zone.upperReference, unit: zone.upperUnit)
        if native {
            zone.lowerAGL = zone.lowerAGL ?? number(p["lower_limit_altitude_meter_agl"])
            zone.upperAGL = zone.upperAGL ?? number(p["upper_limit_altitude_meter_agl"])
        }
    }

    private static func unit(_ value: String) -> String {
        switch value.uppercased() {
        case "F", "FT", "FEET": return "FT"
        case "M", "METERS", "METRES": return "M"
        default: return value.uppercased()
        }
    }

    private static func fromGeoJSON(_ feature: JSONObject, live: Bool) throws -> [DroneguideZone] {
        guard string(feature["type"]) == "Feature", let properties = feature["properties"] as? JSONObject else {
            throw Failure("Invalid GeoJSON feature.")
        }
        if string(properties["type_code"]).uppercased() == "TIME_ZONE" { return [] }
        let featureID = first(string(feature["id"]), number(feature["id"]).flatMap { _ in
            (feature["id"] as? NSNumber)?.stringValue
        } ?? "")
        let id = first(string(properties["identifier"]), string(properties["unique_identifier"]), featureID, string(properties["code"]))
        var zone = try metadata(properties, id: id, live: live)
        altitude(properties, for: &zone, native: true)
        guard let geometry = feature["geometry"] as? JSONObject else { throw Failure.noArea }
        (zone.polygons, zone.circle) = try projection(geometry, live: live)
        return [zone]
    }

    private static func fromED(_ feature: JSONObject) throws -> [DroneguideZone] {
        let zone = try metadata(feature, id: string(feature["identifier"]), live: false)
        guard let volumes = feature["geometry"] as? [JSONObject], !volumes.isEmpty, volumes.count <= maxFeatures else {
            throw Failure("No valid ED-269 volumes were found.")
        }
        return try volumes.enumerated().map { index, volume in
            var volumeZone = zone
            if index > 0 { volumeZone.id += "#\(index + 1)" }
            altitude(volume, for: &volumeZone, native: false)
            guard let geometry = volume["horizontalProjection"] as? JSONObject else { throw Failure("The ED-269 volume has no horizontal projection.") }
            (volumeZone.polygons, volumeZone.circle) = try projection(geometry, live: false)
            return volumeZone
        }
    }

    private static func metadata(_ p: JSONObject, id: String, live: Bool) throws -> DroneguideZone {
        let country = string(p["country"]).uppercased()
        guard country.isEmpty || country == "BE" || country == "BEL" else { throw Failure("Country \(country) is outside Belgium.") }
        guard !id.isEmpty else { throw Failure("No zone identifier was provided.") }
        let restriction: String
        switch string(p["restriction"]).uppercased() {
        case "REQ_AUTHORISATION", "REQ_AUTHORIZATION": restriction = "REQ_AUTHORISATION"
        case "PROHIBITED": restriction = "PROHIBITED"
        case "CONDITIONAL": restriction = "CONDITIONAL"
        case "NO_RESTRICTION": restriction = "NO_RESTRICTION"
        default: throw Failure("Unrecognized zone restriction.")
        }
        let clauses = try (p["applicability"] as? [JSONObject] ?? []).map(DroneguidePeriod.init)
        let (from, until) = try validity(start: string(p["validFrom"]), end: string(p["validUntil"]))
        let oneClause = clauses.count == 1 ? clauses[0] : nil
        let schedule = string(p["schedule"])
        let authorities = (p["zoneAuthority"] as? [JSONObject] ?? []).map { first(string($0["name"]), string($0["service"])) }
            .filter { !$0.isEmpty }
        let reasons = p["reason"] as? [String]
        let reason = [reasons?.joined(separator: ", ") ?? localized(p["reason"]), string(p["otherReasonInfo"])]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        let activity: DroneguideActivity
        switch (live, number(p["active_at_window_start"]), number(p["active_within_window"])) {
        case (true, .some(0), _): activity = .active
        case (true, .some(1), .some(0)): activity = .planned
        case (true, .some(1), _): activity = .inactive
        default: activity = .unknown
        }
        return DroneguideZone(id: id, name: first(localized(p["name"]), id), restriction: restriction,
                              reason: first(reason, string(p["type_code"])),
                              message: first(localized(p["message"]), localized(p["description"])),
                              schedule: first(schedule, clauses.map(\.label).filter { !$0.isEmpty }.joined(separator: " | ")),
                              validFrom: from ?? oneClause?.from, validUntil: until ?? oneClause?.until,
                              authorities: authorities, conditions: p["restrictionConditions"] as? [String] ?? [],
                              activity: activity, liveSnapshot: live, applicability: clauses, freeTextSchedule: !schedule.isEmpty)
    }

    fileprivate static func validity(start: String, end: String) throws -> (Date?, Date?) {
        let from = date(start), until = date(end)
        guard (start.isEmpty || from != nil), (end.isEmpty || until != nil) else { throw Failure("Invalid validity timestamp.") }
        if let from, let until, until < from { throw Failure("The validity end precedes its start.") }
        return (from, until)
    }

    private static func checkCRS(_ object: JSONObject) throws {
        guard let crs = object["crs"], !(crs is NSNull) else { return }
        let properties = (crs as? JSONObject)?["properties"] as? JSONObject
        let name = string(properties?["name"]).uppercased()
        guard name.hasSuffix(":4326") || name.hasSuffix(":CRS84") || name.hasSuffix("/CRS84") else {
            throw Failure("The file does not use WGS 84 coordinates.")
        }
    }

    private static func projection(_ p: JSONObject, live: Bool, depth: Int = 0) throws -> ([[[DroneguidePoint]]], DroneguideCircle?) {
        guard depth < 20 else { throw Failure("The zone geometry is nested too deeply.") }
        switch string(p["type"]).lowercased() {
        case "polygon":
            return ([try polygon(p["coordinates"], live: live)], nil)
        case "multipolygon":
            guard let items = p["coordinates"] as? [Any], !items.isEmpty else { throw Failure("Invalid MultiPolygon coordinates.") }
            var result: [[[DroneguidePoint]]] = []
            for item in items {
                do { result.append(try polygon(item, live: live)) }
                catch Failure.noArea where live { continue }
            }
            guard !result.isEmpty else { throw Failure.noArea }
            return (result, nil)
        case "circle":
            guard let radius = number(p["radius"]), radius > 0, radius <= 1_000_000 else { throw Failure("Invalid zone circle radius.") }
            let circle = DroneguideCircle(center: try point(p["center"]), radiusMeters: radius)
            return ([[circle.ring()]], circle)
        case "geometrycollection":
            var result: [[[DroneguidePoint]]] = []
            guard let items = p["geometries"] as? [JSONObject] else { throw Failure("Invalid GeometryCollection.") }
            for item in items {
                if ["linestring", "multilinestring", "point", "multipoint"].contains(string(item["type"]).lowercased()) { continue }
                do { result += try projection(item, live: live, depth: depth + 1).0 }
                catch Failure.noArea where live { continue }
            }
            guard !result.isEmpty else { throw Failure.noArea }
            return (result, nil)
        case "linestring", "multilinestring", "point", "multipoint":
            if live { throw Failure.noArea }
            throw Failure("Unsupported zone geometry.")
        default:
            throw Failure("Unsupported zone geometry.")
        }
    }

    private static func polygon(_ value: Any?, live: Bool) throws -> [[DroneguidePoint]] {
        guard let items = value as? [[Any]] else { throw Failure("Invalid polygon coordinates.") }
        var result: [[DroneguidePoint]] = []
        for (index, item) in items.enumerated() {
            var ring = try item.map(point)
            guard let first = ring.first, hasArea(ring, origin: first) else {
                if live && index > 0 { continue }
                throw Failure.noArea
            }
            if ring.last != first { ring.append(first) }
            result.append(ring)
        }
        guard !result.isEmpty else { throw Failure.noArea }
        return result
    }

    private static func point(_ value: Any?) throws -> DroneguidePoint {
        guard let p = value as? [Any], p.count >= 2, let longitude = number(p[0]), let latitude = number(p[1]),
              abs(longitude) <= 180, abs(latitude) <= 90 else { throw Failure("Invalid map coordinate.") }
        return DroneguidePoint(latitude: latitude, longitude: longitude)
    }

    private static func hasArea(_ ring: [DroneguidePoint], origin: DroneguidePoint) -> Bool {
        guard ring.count >= 3, let last = ring.last else { return false }
        var previous = last
        var signedArea = 0.0
        for position in ring {
            let x1 = (previous.longitude - origin.longitude).remainder(dividingBy: 360)
            let x2 = (position.longitude - origin.longitude).remainder(dividingBy: 360)
            signedArea += x1 * (position.latitude - origin.latitude) - x2 * (previous.latitude - origin.latitude)
            previous = position
        }
        return signedArea != 0
    }

    private static func localized(_ value: Any?) -> String {
        var choices = value as? [String: String]
        if let value = value as? String {
            let direct = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if direct.hasPrefix("{") { choices = try? JSONDecoder().decode([String: String].self, from: Data(direct.utf8)) }
            if choices == nil { return direct }
        }
        guard let choices else { return "" }
        let preferred = ["nl", "nl-BE", "en", "fr", "de"]
        return (preferred + choices.keys.sorted()).compactMap { choices[$0] }.map { string($0) }.first { !$0.isEmpty } ?? ""
    }

    fileprivate static func string(_ value: Any?) -> String {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let number = value.doubleValue
        return number.isFinite ? number : nil
    }

    private static func first(_ values: String...) -> String { values.first { !$0.isEmpty } ?? "" }

    fileprivate enum Failure: LocalizedError {
        case message(String)
        case noArea

        init(_ message: String) { self = .message(message) }

        var errorDescription: String? {
            switch self {
            case .message(let message): return message
            case .noArea: return "The zone geometry has no drawable area."
            }
        }
    }
}

private typealias JSONObject = [String: Any]

fileprivate struct DroneguidePeriod: Sendable {
    let from: Date?
    let until: Date?
    private let permanent: Bool
    private let daily: [DroneguideDaily]
    let label: String

    init(_ source: JSONObject) throws {
        let start = DroneguideData.string(source["startDateTime"])
        let end = DroneguideData.string(source["endDateTime"])
        (from, until) = try DroneguideData.validity(start: start, end: end)
        permanent = DroneguideData.string(source["permanent"]).uppercased() == "YES"
        if let schedule = source["schedule"], !(schedule is NSNull) {
            daily = (schedule as? [JSONObject]).map { $0.map(DroneguideDaily.init) } ?? [DroneguideDaily([:])]
        } else {
            daily = []
        }
        var details: [String] = permanent ? ["Permanent"] : []
        if !start.isEmpty { details.append("From \(start)") }
        if !end.isEmpty { details.append("Until \(end)") }
        details += daily.map(\.label).filter { !$0.isEmpty }
        label = details.joined(separator: " · ")
    }

    func activity(at now: Date) -> DroneguideActivity {
        let dates = Self.dateActivity(from: from, until: until, permanent: permanent, at: now)
        if dates == .inactive || daily.isEmpty { return dates }
        let times = Self.any(daily.map { $0.activity(at: now) })
        return times == .active ? dates : times
    }

    static func dateActivity(from: Date?, until: Date?, permanent: Bool, at now: Date) -> DroneguideActivity {
        if let from, let until, from == until { return .unknown }
        if from.map({ now < $0 }) == true || until.map({ now >= $0 }) == true { return .inactive }
        return permanent || (from != nil && until != nil) ? .active : .unknown
    }

    static func any(_ states: [DroneguideActivity]) -> DroneguideActivity {
        if states.contains(.active) { return .active }
        if states.contains(.unknown) { return .unknown }
        return .inactive
    }
}

private struct DroneguideDaily: Sendable {
    private static let dayNames = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]
    private let days: [String]
    private let start: Clock?
    private let end: Clock?
    let label: String

    init(_ source: JSONObject) {
        days = (source["day"] as? [String] ?? []).map { DroneguideData.string($0).uppercased() }
        let startText = DroneguideData.string(source["startTime"])
        let endText = DroneguideData.string(source["endTime"])
        start = Clock(startText)
        end = Clock(endText)
        label = startText.isEmpty && endText.isEmpty ? "" : "\(days.joined(separator: ", ")) \(startText) – \(endText)"
    }

    func activity(at now: Date) -> DroneguideActivity {
        guard let start, let end, start.offset == end.offset, start.seconds != end.seconds,
              !days.isEmpty, days.allSatisfy({ $0 == "ANY" || Self.dayNames.contains($0) }) else { return .unknown }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let local = now.addingTimeInterval(TimeInterval(start.offset))
        let midnight = calendar.startOfDay(for: local)
        let from = midnight.addingTimeInterval(start.seconds)
        let until = midnight.addingTimeInterval(end.seconds)
        let today = calendar.component(.weekday, from: local) - 1
        let overnight = start.seconds > end.seconds
        let windowStartDay = overnight && local < until ? (today + 6) % 7 : today
        let within = overnight ? (local >= from || local < until) : (local >= from && local < until)
        return within && (days.contains("ANY") || days.contains(Self.dayNames[windowStartDay])) ? .active : .inactive
    }

    private struct Clock: Sendable {
        let seconds: Double
        let offset: Int

        init?(_ value: String) {
            let local: Substring
            if value.hasSuffix("Z") {
                local = value.dropLast()
                offset = 0
            } else {
                guard let sign = value.lastIndex(where: { $0 == "+" || $0 == "-" }) else { return nil }
                local = value[..<sign]
                let parts = value[value.index(after: sign)...].split(separator: ":", omittingEmptySubsequences: false)
                guard parts.count == 2, let hour = Self.component(parts[0], max: 23),
                      let minute = Self.component(parts[1], max: 59) else { return nil }
                offset = (value[sign] == "-" ? -1 : 1) * (hour * 3600 + minute * 60)
            }
            let parts = local.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3, let hour = Self.component(parts[0], max: 23),
                  let minute = Self.component(parts[1], max: 59) else { return nil }
            let secondParts = parts[2].split(separator: ".", omittingEmptySubsequences: false)
            guard (1...2).contains(secondParts.count), secondParts[0].count == 2,
                  secondParts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
                  let second = Double(parts[2]), second >= 0, second < 60 else { return nil }
            seconds = Double(hour * 3600 + minute * 60) + second
        }

        private static func component(_ value: Substring, max: Int) -> Int? {
            guard value.utf8.count == 2, value.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = Int(value), number <= max else { return nil }
            return number
        }
    }
}

private extension DroneguideCircle {
    func ring() -> [DroneguidePoint] {
        let count = min(720, max(96, Int(ceil(Double.pi / acos(1 - min(0.5 / radiusMeters, 1))))))
        let points = (0..<count).map { destination(bearing: 2 * .pi * Double($0) / Double(count)) }
        return points + [points[0]]
    }

    /// Vincenty's direct solution on WGS 84, as in the Windows port.
    func destination(bearing: Double) -> DroneguidePoint {
        let a = 6_378_137.0, f = 1 / 298.257_223_563, radians = Double.pi / 180
        let b = a * (1 - f)
        let sinBearing = sin(bearing), cosBearing = cos(bearing)
        let tanU = (1 - f) * tan(center.latitude * radians)
        let cosU = 1 / hypot(1, tanU), sinU = tanU / hypot(1, tanU)
        let sigma1 = atan2(tanU, cosBearing)
        let sinAlpha = cosU * sinBearing, cosSqAlpha = 1 - sinAlpha * sinAlpha
        let uSq = cosSqAlpha * (a * a - b * b) / (b * b)
        let littleA = 1 + uSq / 16384 * (4096 + uSq * (-768 + uSq * (320 - 175 * uSq)))
        let littleB = uSq / 1024 * (256 + uSq * (-128 + uSq * (74 - 47 * uSq)))
        let base = radiusMeters / (b * littleA)
        var sigma = base
        for _ in 0..<20 {
            let cosMid = cos(2 * sigma1 + sigma)
            let midSq = cosMid * cosMid
            let sinSigma = sin(sigma), cosSigma = cos(sigma)
            let delta = littleB * sinSigma * (cosMid + littleB / 4 * (cosSigma * (-1 + 2 * midSq) -
                littleB / 6 * cosMid * (-3 + 4 * sinSigma * sinSigma) * (-3 + 4 * midSq)))
            let next = base + delta
            let converged = abs(next - sigma) < 1e-12
            sigma = next
            if converged { break }
        }
        let sinSigma = sin(sigma), cosSigma = cos(sigma), cosMid = cos(2 * sigma1 + sigma)
        let tmp = sinU * sinSigma - cosU * cosSigma * cosBearing
        let lat = atan2(sinU * cosSigma + cosU * sinSigma * cosBearing, (1 - f) * hypot(sinAlpha, tmp))
        let lambda = atan2(sinSigma * sinBearing, cosU * cosSigma - sinU * sinSigma * cosBearing)
        let c = f / 16 * cosSqAlpha * (4 + f * (4 - 3 * cosSqAlpha))
        let lonDelta = lambda - (1 - c) * f * sinAlpha * (sigma + c * sinSigma * (cosMid + c * cosSigma * (-1 + 2 * cosMid * cosMid)))
        return DroneguidePoint(latitude: lat / radians, longitude: (center.longitude + lonDelta / radians).remainder(dividingBy: 360))
    }
}
