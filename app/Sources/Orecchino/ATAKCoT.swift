// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct ATAKEndpoint: Equatable, Sendable {
    static let defaultPort = 4242
    let host: String
    let port: Int

    var display: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }

    init(host: String, port: Int) throws {
        var name = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("[") && name.hasSuffix("]") {
            name = String(name.dropFirst().dropLast())
            guard name.contains(":") else { throw ATAKError.host }
        }
        guard (1...65535).contains(port) else { throw ATAKError.port }
        guard !name.isEmpty, name.utf8.count <= 253, !name.utf8.contains(0) else {
            throw ATAKError.host
        }
        if let direct = Self.literalIsUnicast(name) {
            guard direct else { throw ATAKError.host }
        } else {
            let labels = name.split(separator: ".", omittingEmptySubsequences: false)
            let domain = name.hasSuffix(".") ? labels.dropLast() : labels[...]
            guard !domain.isEmpty, name.utf8.contains(where: {
                (65...90).contains($0) || (97...122).contains($0) || $0 == 45
            }), domain.allSatisfy({ label in
                !label.isEmpty && label.utf8.count <= 63 &&
                    label.first != "-" && label.last != "-" &&
                    label.utf8.allSatisfy(Self.hostByte)
            }) else { throw ATAKError.host }
            name = name.lowercased()
        }
        self.host = name
        self.port = port
    }

    private static func hostByte(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) ||
            (48...57).contains(byte) || byte == 45
    }

    /// A non-IP name returns nil. An IP without a unicast destination
    /// returns false so the exporter never sends to a multicast group.
    private static func literalIsUnicast(_ host: String) -> Bool? {
        var ipv4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            let value = UInt32(bigEndian: ipv4.s_addr)
            return value != 0 && value != UInt32.max && !(224...239).contains(value >> 24)
        }
        let scoped = host.split(separator: "%", omittingEmptySubsequences: false)
        var ipv6 = in6_addr()
        if let address = scoped.first, address.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            guard scoped.count == 1 || (scoped.count == 2 && !scoped[1].isEmpty &&
                scoped[1].utf8.allSatisfy({ hostByte($0) || $0 == 46 || $0 == 95 })) else { return false }
            return withUnsafeBytes(of: ipv6) { bytes in
                guard bytes[0] != 0xff, bytes.contains(where: { $0 != 0 }) else { return false }
                // An IPv4-mapped address follows the same rules as IPv4.
                if bytes.prefix(10).allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
                    let address = bytes.suffix(4)
                    return !address.allSatisfy({ $0 == 0 }) && !address.allSatisfy({ $0 == 255 }) &&
                        !(224...239).contains(bytes[12])
                }
                return true
            }
        }
        return nil
    }

    /// Resolve once per connection to prevent a DNS hostname that resolves
    /// to a multicast address from turning a direct output into a group feed.
    func resolve() throws -> String {
        if Self.literalIsUnicast(host) == true { return host }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if canImport(Darwin)
        hints.ai_socktype = SOCK_DGRAM
        #else
        hints.ai_socktype = Int32(SOCK_DGRAM.rawValue)
        #endif
        hints.ai_protocol = Int32(IPPROTO_UDP)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
            throw ATAKError.resolution
        }
        defer { freeaddrinfo(first) }
        var item: UnsafeMutablePointer<addrinfo>? = first
        while let address = item {
            let info = address.pointee
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(info.ai_addr, info.ai_addrlen, &buffer,
                           socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                let numeric = String(decoding: bytes, as: UTF8.self)
                if Self.literalIsUnicast(numeric) == true { return numeric }
            }
            item = info.ai_next
        }
        throw ATAKError.resolution
    }
}

enum ATAKError: LocalizedError {
    case host, port, resolution

    var errorDescription: String? {
        switch self {
        case .host: return "Enter a valid ATAK device host name or unicast IP address."
        case .port: return "Enter an ATAK UDP port from 1 to 65535."
        case .resolution: return "The ATAK host could not be resolved to a unicast address."
        }
    }
}

struct ATAKFix: Equatable, Sendable {
    let observedAt: Date
    let latitude: Double
    let longitude: Double
    let hae: Double?

    func fresh(at now: Date) -> Bool {
        let age = now.timeIntervalSince(observedAt)
        return age >= 0 && age < ATAKCoT.lifetime &&
            latitude.isFinite && abs(latitude) <= 90 &&
            longitude.isFinite && abs(longitude) <= 180 &&
            (abs(latitude) >= 5 || abs(longitude) >= 5)
    }
}

struct ATAKSample: Sendable {
    let sequence: Int
    let fix: ATAKFix
}

enum ATAKCoT {
    static let lifetime: TimeInterval = 60
    static let minimumInterval: TimeInterval = 2
    static let maximumBatch = 8
    private static let locale = Locale(identifier: "en_US_POSIX")
    private static let unknown = "9999999.0"

    static func event(_ sample: ATAKSample, session: String, at now: Date) -> Data? {
        let fix = sample.fix
        guard sample.sequence > 0, fix.fresh(at: now) else { return nil }
        let clock = ISO8601DateFormatter()
        clock.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        clock.timeZone = TimeZone(secondsFromGMT: 0)
        let date = clock.string(from: fix.observedAt)
        let stale = clock.string(from: fix.observedAt.addingTimeInterval(lifetime))
        let uid = escaped("orecchino-rid-\(session)-\(sample.sequence)")
        let callsign = escaped("Orecchino UAS \(sample.sequence)")
        let lat = String(format: "%.7f", locale: locale, fix.latitude)
        let lon = String(format: "%.7f", locale: locale, fix.longitude)
        // RID alt_geo is geodetic ellipsoid height. Barometric or above
        // ground/takeoff heights have a different reference.
        let hae: String
        if let known = fix.hae, known.isFinite, known > -999, known <= 31767.5 {
            hae = String(format: "%.1f", locale: locale, known)
        } else {
            hae = unknown
        }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <event version="2.0" uid="\(uid)" type="a-u-A" how="m-r" access="Undefined" time="\(date)" start="\(date)" stale="\(stale)"><point lat="\(lat)" lon="\(lon)" hae="\(hae)" ce="\(unknown)" le="\(unknown)"/><detail><contact callsign="\(callsign)"/></detail></event>
        """
        return Data(xml.utf8)
    }

    private static func escaped(_ string: String) -> String {
        string.unicodeScalars.reduce(into: "") { result, scalar in
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default:
                if scalar.value >= 0x20 && scalar.value != 0xfffe && scalar.value != 0xffff {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
    }
}

/// Keeps one attempt timestamp and acknowledged local send per live contact.
/// One fast-moving drone cannot take all slots from lower-rate contacts.
struct ATAKSendPlan {
    private struct Attempt {
        let at: Date
        var sentFixAt: Date?
    }
    private var attempts: [Int: Attempt] = [:]

    mutating func batch(_ samples: [ATAKSample], at now: Date) -> [ATAKSample] {
        let fresh = samples.filter { $0.sequence > 0 && $0.fix.fresh(at: now) }
        let live = Set(fresh.map(\.sequence))
        attempts = attempts.filter { live.contains($0.key) }
        let sorted = fresh.filter { sample in
            guard let attempt = attempts[sample.sequence] else { return true }
            return sample.fix.observedAt > (attempt.sentFixAt ?? .distantPast) &&
                now.timeIntervalSince(attempt.at) >= ATAKCoT.minimumInterval
        }.sorted { left, right in
            let a = attempts[left.sequence]?.at ?? .distantPast
            let b = attempts[right.sequence]?.at ?? .distantPast
            return a == b ? left.sequence < right.sequence : a < b
        }
        var selected: [ATAKSample] = []
        for sample in sorted where selected.count < ATAKCoT.maximumBatch {
            if attempts[sample.sequence]?.at == now { continue }
            attempts[sample.sequence] = Attempt(at: now, sentFixAt: attempts[sample.sequence]?.sentFixAt)
            selected.append(sample)
        }
        return selected
    }

    mutating func sent(_ sample: ATAKSample) {
        guard var attempt = attempts[sample.sequence] else { return }
        attempt.sentFixAt = max(attempt.sentFixAt ?? .distantPast, sample.fix.observedAt)
        attempts[sample.sequence] = attempt
    }
}
