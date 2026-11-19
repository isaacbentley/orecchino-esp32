// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import CoreFoundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum DroneguideWFS {
    static let website = URL(string: "https://map.droneguide.be/")!
    static let refreshInterval: TimeInterval = 15 * 60
    private static let endpoint = URL(string: "https://map.droneguide.be/ows")!
    private static let pageSize = 2_000
    private static let maxPages = 12

    static func requestURL(start: Date, index: Int) -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let from = formatter.string(from: start).replacingOccurrences(of: ":", with: "\\:")
        let to = formatter.string(from: start.addingTimeInterval(24 * 60 * 60))
            .replacingOccurrences(of: ":", with: "\\:")
        var url = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        let items = [
            URLQueryItem(name: "service", value: "WFS"),
            URLQueryItem(name: "version", value: "2.0.0"),
            URLQueryItem(name: "request", value: "GetFeature"),
            URLQueryItem(name: "typeNames", value: "uaszone"),
            URLQueryItem(name: "srsName", value: "EPSG:4326"),
            URLQueryItem(name: "outputFormat", value: "application/json"),
            URLQueryItem(name: "cql_filter", value: DroneguideData.altitudeCQL),
            URLQueryItem(name: "viewParams", value: "window_start:\(from);window_end:\(to);show_planned:true"),
            URLQueryItem(name: "count", value: String(pageSize)),
            URLQueryItem(name: "sortBy", value: "unique_identifier A"),
            URLQueryItem(name: "startIndex", value: String(index)),
        ]
        let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        url.percentEncodedQueryItems = items.map {
            URLQueryItem(name: $0.name, value: $0.value?.addingPercentEncoding(withAllowedCharacters: unreserved))
        }
        return url.url!
    }

    static func fetch(start: Date) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 38
        configuration.timeoutIntervalForResource = 38
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: RedirectPolicy(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var total: Int?
        var remaining = DroneguideData.maxJSONBytes
        var features: [[String: Any]] = []
        var envelope: [String: Any] = [:]
        var identifiers = Set<String>()

        for _ in 0..<maxPages {
            try Task.checkCancellation()
            var request = URLRequest(url: requestURL(start: start, index: features.count),
                                     cachePolicy: .reloadIgnoringLocalCacheData)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Orecchino macOS (Droneguide WFS)", forHTTPHeaderField: "User-Agent")
            let (url, response) = try await session.download(for: request)
            defer { try? FileManager.default.removeItem(at: url) }
            guard let response = response as? HTTPURLResponse else { throw Failure.invalidResponse }
            guard response.statusCode == 200 else { throw Failure.http(response.statusCode) }
            let raw = try read(url, limit: remaining)
            remaining -= raw.count
            let page = try decodePage(raw)
            if let total {
                guard page.total == total else { throw Failure.incomplete }
            } else {
                total = page.total
                envelope = page.envelope
            }
            guard features.count + page.features.count <= page.total else { throw Failure.incomplete }
            for feature in page.features {
                if let id = feature["id"] as? String, !id.isEmpty,
                   !identifiers.insert(id).inserted { throw Failure.incomplete }
                features.append(feature)
            }
            if features.count == page.total {
                envelope["features"] = features
                envelope["numberReturned"] = features.count
                let snapshot = try JSONSerialization.data(withJSONObject: envelope)
                guard snapshot.count <= DroneguideData.maxJSONBytes else { throw Failure.tooLarge }
                return snapshot
            }
        }
        throw Failure.incomplete
    }

    static func read(_ url: URL, limit: Int = DroneguideData.maxJSONBytes) throws -> Data {
        guard limit > 0 else { throw Failure.tooLarge }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var data = Data()
        while let chunk = try file.read(upToCount: min(65_536, limit - data.count + 1)), !chunk.isEmpty {
            data.append(chunk)
            if data.count > limit { throw Failure.tooLarge }
        }
        return data
    }

    private static func decodePage(_ bytes: Data) throws -> (envelope: [String: Any], features: [[String: Any]], total: Int) {
        guard var envelope = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
              envelope["type"] as? String == "FeatureCollection",
              let features = envelope.removeValue(forKey: "features") as? [[String: Any]],
              count(envelope["numberReturned"]) == features.count, !features.isEmpty else {
            throw Failure.invalidResponse
        }
        let matched = count(envelope["numberMatched"])
        let advertised = count(envelope["totalFeatures"])
        guard let total = matched ?? advertised, total > 0, total <= DroneguideData.maxFeatures,
              matched == nil || advertised == nil || matched == advertised else { throw Failure.incomplete }
        return (envelope, features, total)
    }

    private static func count(_ value: Any?) -> Int? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        return Int(exactly: value.doubleValue)
    }

    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            let url = request.url
            completionHandler(url?.scheme == "https" && url?.host == "map.droneguide.be" &&
                              url?.user == nil && url?.password == nil && url?.port == nil ? request : nil)
        }
    }

    enum Failure: LocalizedError {
        case invalidResponse, http(Int), incomplete, tooLarge

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "Droneguide sent an unreadable response."
            case .http(let status): return "Droneguide returned HTTP \(status)."
            case .incomplete: return "Droneguide returned an incomplete zone collection."
            case .tooLarge: return "The Droneguide data exceeds the size limit."
            }
        }
    }
}
