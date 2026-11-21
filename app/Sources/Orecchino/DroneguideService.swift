// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation

@MainActor
@Observable
final class DroneguideService {
    enum Source: Equatable { case imported, live }

    private struct Record: Codable, Sendable {
        let raw: Data
        let loadedAt: Date
        let snapshotAt: Date?
    }

    private struct DiskState: Codable, Sendable {
        var version = 1
        var liveEnabled = false
        var imported: Record?
        var live: Record?
    }

    private struct Snapshot: Sendable {
        let revision = UUID()
        let record: Record
        let parsed: DroneguideParsed
    }

    private static let maximumCacheBytes = (2 * DroneguideData.maxJSONBytes + 2) / 3 * 4 + 65_536
    private static let visibilityKey = "droneguideLayerVisible"
    private static let activeKey = "droneguideActiveOnly"

    private let cacheURL: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var lastAttempt = Date.distantPast
    @ObservationIgnored private var generation = 0
    private var imported: Snapshot?
    private var online: Snapshot?
    private(set) var liveEnabled = false
    private(set) var isRefreshing = false
    private(set) var isImporting = false
    private(set) var refreshError: String?
    private(set) var actionError: String?

    var showLayer: Bool {
        didSet { defaults.set(showLayer, forKey: Self.visibilityKey) }
    }

    var activeOnly: Bool {
        didSet { defaults.set(activeOnly, forKey: Self.activeKey) }
    }

    init(cacheURL: URL? = nil, defaults: UserDefaults = .standard) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.cacheURL = cacheURL ?? support.appendingPathComponent("Orecchino/Droneguide.json")
        self.defaults = defaults
        self.showLayer = defaults.object(forKey: Self.visibilityKey) as? Bool ?? true
        self.activeOnly = defaults.bool(forKey: Self.activeKey)
    }

    private var chosen: Snapshot? {
        if (liveEnabled || imported == nil), let online { return online }
        return imported
    }

    var source: Source? { chosen.map { $0.record.snapshotAt == nil ? .imported : .live } }
    var zones: [DroneguideZone] { chosen?.parsed.zones ?? [] }
    var revision: UUID? { chosen?.revision }
    var loadedAt: Date? { chosen?.record.loadedAt }
    var snapshotAt: Date? { chosen?.record.snapshotAt }
    var omittedGeometryCount: Int { chosen?.parsed.omittedGeometryCount ?? 0 }
    var unknownAltitudeCount: Int { chosen?.parsed.unknownAltitudeCount ?? 0 }

    func stale(at now: Date) -> Bool {
        guard let snapshotAt else { return false }
        let age = now.timeIntervalSince(snapshotAt)
        return !liveEnabled || refreshError != nil || age < 0 || age > 2 * DroneguideWFS.refreshInterval
    }

    func activity(for zone: DroneguideZone, at now: Date) -> DroneguideActivity {
        if source == .live { return stale(at: now) ? .unknown : zone.activity }
        return zone.activity(at: now)
    }

    func includes(_ zone: DroneguideZone, at now: Date) -> Bool {
        !activeOnly || activity(for: zone, at: now) == .active
    }

    func start() {
        guard timer == nil else { return }
        restore()
        if liveEnabled { refresh() }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, Date().timeIntervalSince(self.lastAttempt) >= DroneguideWFS.refreshInterval else { return }
                self.refresh()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func setLive(_ enabled: Bool) {
        guard enabled != liveEnabled, !isImporting else { return }
        actionError = nil
        do {
            try persist(enabled: enabled, imported: imported?.record, live: online?.record)
            liveEnabled = enabled
            refreshError = nil
            if enabled { refresh() } else { cancelRefresh() }
        } catch {
            actionError = "The Droneguide setting could not be saved. \(error.localizedDescription)"
        }
    }

    func importFile(_ url: URL) async {
        guard !isImporting else { return }
        actionError = nil
        isImporting = true
        defer { isImporting = false }
        do {
            let snapshot = try await Task.detached(priority: .userInitiated) {
                let raw = try DroneguideWFS.read(url)
                return Snapshot(record: Record(raw: raw, loadedAt: Date(), snapshotAt: nil),
                                parsed: try DroneguideData.parse(raw))
            }.value
            try Task.checkCancellation()
            try persist(enabled: false, imported: snapshot.record, live: online?.record)
            cancelRefresh()
            liveEnabled = false
            refreshError = nil
            imported = snapshot
            showLayer = true
        } catch {
            actionError = "The Droneguide file could not be imported. \(error.localizedDescription)"
        }
    }

    func refresh() {
        guard liveEnabled, !isRefreshing, !isImporting else { return }
        generation += 1
        let id = generation
        let start = Date()
        lastAttempt = start
        isRefreshing = true
        actionError = nil
        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let raw = try await DroneguideWFS.fetch(start: start)
                let parsed = try await Task.detached(priority: .utility) {
                    try DroneguideData.parse(raw, live: true)
                }.value
                guard generation == id else { return }
                let record = Record(raw: raw, loadedAt: Date(), snapshotAt: start)
                try persist(enabled: true, imported: imported?.record, live: record)
                online = Snapshot(record: record, parsed: parsed)
                refreshError = nil
            } catch {
                guard generation == id else { return }
                refreshError = "Droneguide refresh failed. \(error.localizedDescription)"
            }
            isRefreshing = false
            refreshTask = nil
        }
    }

    private func cancelRefresh() {
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
    }

    private func restore() {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return }
        do {
            let state = try JSONDecoder().decode(DiskState.self, from: DroneguideWFS.read(cacheURL, limit: Self.maximumCacheBytes))
            guard state.version == 1 else { throw DroneguideWFS.Failure.invalidResponse }
            liveEnabled = state.liveEnabled
            if let record = state.imported { imported = restore(record, live: false) }
            if let record = state.live { online = restore(record, live: true) }
        } catch {
            actionError = "Saved Droneguide data could not be read. \(error.localizedDescription)"
        }
    }

    private func restore(_ record: Record, live: Bool) -> Snapshot? {
        do {
            guard live == (record.snapshotAt != nil) else { throw DroneguideWFS.Failure.invalidResponse }
            return Snapshot(record: record, parsed: try DroneguideData.parse(record.raw, live: live))
        } catch {
            actionError = "Saved Droneguide data could not be read. \(error.localizedDescription)"
            return nil
        }
    }

    private func persist(enabled: Bool, imported: Record?, live: Record?) throws {
        let data = try JSONEncoder().encode(DiskState(liveEnabled: enabled, imported: imported, live: live))
        guard data.count <= Self.maximumCacheBytes else { throw DroneguideWFS.Failure.tooLarge }
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: cacheURL, options: .atomic)
    }
}
