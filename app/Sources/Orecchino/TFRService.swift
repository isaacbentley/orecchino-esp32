import Foundation
import CoreLocation
import Observation

/// One active Temporary Flight Restriction polygon from the FAA feed.
struct TFRZone: Identifiable {
    let id: String
    let notam: String
    let title: String
    let legal: String       // FAA category: HAZARDS, SECURITY, VIP, ...
    let state: String?
    let outerRing: [CLLocationCoordinate2D]
    let centroid: CLLocationCoordinate2D
}

/// Fetches active TFR polygons from the FAA's GeoServer (the same WFS layer
/// tfr.faa.gov's own map uses) and refreshes periodically.
@MainActor
@Observable
final class TFRService {
    enum Status: Equatable {
        case idle, loading, loaded(Int, Date), failed(String)
        var label: String {
            switch self {
            case .idle: return "TFR —"
            case .loading: return "TFR …"
            case .loaded(let n, _): return "TFR \(n)"
            case .failed: return "TFR fail"
            }
        }
    }

    var zones: [TFRZone] = []
    var status: Status = .idle

    private static let url = URL(string:
        "https://tfr.faa.gov/geoserver/TFR/ows?service=WFS&version=1.1.0" +
        "&request=GetFeature&typeName=TFR:V_TFR_LOC&outputFormat=application/json")!
    private static let refreshInterval: TimeInterval = 15 * 60

    @ObservationIgnored private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval,
                                     repeats: true) { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { AppModel.shared.tfr.refresh() }
            }
        }
    }

    func refresh() {
        if case .loading = status { return }
        status = .loading
        Task { [weak self] in
            do {
                var req = URLRequest(url: Self.url)
                req.timeoutInterval = 30
                let (data, _) = try await URLSession.shared.data(for: req)
                let zones = try Self.parse(data)
                await MainActor.run {
                    self?.zones = zones
                    self?.status = .loaded(zones.count, Date())
                }
            } catch {
                await MainActor.run {
                    self?.status = .failed(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - GeoJSON parsing

    private struct Collection: Decodable { var features: [Feature] }
    private struct Feature: Decodable {
        var geometry: Geometry?
        var properties: Props
    }
    private struct Props: Decodable {
        var GID: Int?
        var NOTAM_KEY: String?
        var TITLE: String?
        var STATE: String?
        var LEGAL: String?
    }
    private struct Geometry: Decodable {
        var type: String
        var polygons: [[[[Double]]]]   // normalized to MultiPolygon shape

        enum CodingKeys: String, CodingKey { case type, coordinates }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try c.decode(String.self, forKey: .type)
            if type == "MultiPolygon" {
                polygons = try c.decode([[[[Double]]]].self, forKey: .coordinates)
            } else if type == "Polygon" {
                polygons = [try c.decode([[[Double]]].self, forKey: .coordinates)]
            } else {
                polygons = []
            }
        }
    }

    nonisolated private static func parse(_ data: Data) throws -> [TFRZone] {
        let fc = try JSONDecoder().decode(Collection.self, from: data)
        var out: [TFRZone] = []
        for f in fc.features {
            guard let g = f.geometry else { continue }
            for (pi, poly) in g.polygons.enumerated() {
                guard let outer = poly.first, outer.count >= 3 else { continue }
                let ring = outer.compactMap { pt -> CLLocationCoordinate2D? in
                    guard pt.count >= 2 else { return nil }
                    let lon = pt[0], lat = pt[1]
                    guard abs(lat) <= 90, abs(lon) <= 180 else { return nil }
                    return CLLocationCoordinate2D(latitude: lat, longitude: lon)
                }
                guard ring.count >= 3 else { continue }
                let cLat = ring.map(\.latitude).reduce(0, +) / Double(ring.count)
                let cLon = ring.map(\.longitude).reduce(0, +) / Double(ring.count)
                let notam = f.properties.NOTAM_KEY ?? "unknown"
                out.append(TFRZone(
                    id: "\(f.properties.GID ?? 0)-\(notam)-\(pi)",
                    notam: notam,
                    title: f.properties.TITLE ?? "TFR",
                    legal: f.properties.LEGAL ?? "TFR",
                    state: f.properties.STATE,
                    outerRing: ring,
                    centroid: CLLocationCoordinate2D(latitude: cLat, longitude: cLon)))
            }
        }
        return out
    }
}
