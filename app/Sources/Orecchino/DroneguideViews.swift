// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import MapKit
import SwiftUI
import UniformTypeIdentifiers

private let droneguideColor = Color(hex: 0xBA8CFF)

struct DroneguideMapZone: Identifiable {
    struct Part: Identifiable {
        let id: Int
        let overlay: MKPolygon
        let rings: [[CLLocationCoordinate2D]]

        init?(id: Int, source: [[DroneguidePoint]]) {
            let rings = source.map { ring in
                ring.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            }
            guard let outer = rings.first, outer.count >= 3 else { return nil }
            let holes = rings.dropFirst().filter { $0.count >= 3 }.map {
                MKPolygon(coordinates: $0, count: $0.count)
            }
            self.id = id
            self.overlay = MKPolygon(coordinates: outer, count: outer.count, interiorPolygons: holes)
            self.rings = rings
        }

        func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
            guard let outer = rings.first, overlay.boundingMapRect.contains(MKMapPoint(coordinate)),
                  TFRShape.contains(outer, coordinate) else { return false }
            return !rings.dropFirst().contains { $0.count >= 3 && TFRShape.contains($0, coordinate) }
        }
    }

    var id: String { zone.id }
    let zone: DroneguideZone
    let parts: [Part]

    init(_ zone: DroneguideZone) {
        self.zone = zone
        parts = zone.polygons.enumerated().compactMap { Part(id: $0.offset, source: $0.element) }
    }

    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        parts.contains { $0.contains(coordinate) }
    }
}

struct DroneguideMapLayer: MapContent {
    let zones: [DroneguideMapZone]
    let active: Set<String>

    @MapContentBuilder var body: some MapContent {
        ForEach(zones) { drawing in
            let isActive = active.contains(drawing.id)
            ForEach(drawing.parts) { part in
                MapPolygon(part.overlay)
                    .foregroundStyle(droneguideColor.opacity(isActive ? 0.17 : 0.045))
                    .stroke(droneguideColor.opacity(isActive ? 0.85 : 0.45),
                            style: StrokeStyle(lineWidth: 1.25, dash: isActive ? [] : [4, 4]))
            }
        }
    }
}

@MainActor struct DroneguideSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var service = model.droneguide
        let live = Binding(get: { service.liveEnabled }, set: { service.setLive($0) })
        Section("Belgian geozones · Droneguide") {
            Toggle("Show Droneguide layer", isOn: $service.showLayer)
            Toggle("Show active zones only", isOn: $service.activeOnly)
                .toggleStyle(.switch)
            Toggle("Fetch live data from skeyes", isOn: live)
                .disabled(service.isImporting)
            Text("The layer shows zones that overlap 0–500 ft AGL. Enable automatic API access with skeyes permission. Live data refreshes every 15 minutes.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Refresh Now") { service.refresh() }
                    .disabled(!service.liveEnabled || service.isRefreshing || service.isImporting)
                Button("Import JSON…") { importFile(service) }
                    .disabled(service.isImporting)
                Button("Show on Map") { showBelgium(service) }
                    .disabled(service.zones.isEmpty)
            }
            Text(summary(service, at: model.now))
                .font(.caption)
                .foregroundStyle(service.actionError != nil || service.refreshError != nil ? Theme.warn : Theme.muted)
                .textSelection(.enabled)
            Link("Open official Droneguide map", destination: DroneguideWFS.website)
        }
    }

    private func summary(_ service: DroneguideService, at now: Date) -> String {
        var text: [String] = []
        if let error = service.actionError ?? service.refreshError { text.append(error) }
        if service.isImporting { text.append("Importing Droneguide data…") }
        if service.isRefreshing { text.append("Refreshing Droneguide data…") }
        if let loaded = service.loadedAt {
            let count = service.zones.filter { service.includes($0, at: now) }.count
            let source = service.source == .live ? "skeyes API" : "JSON import"
            text.append("\(count) of \(service.zones.count) zones shown · \(source) · \(loaded.formatted(date: .abbreviated, time: .shortened))")
            if let snapshot = service.snapshotAt {
                text.append("Activity at \(snapshot.formatted(date: .abbreviated, time: .shortened)).")
            }
            if service.stale(at: now) { text.append("Cached data · active status is unconfirmed.") }
            if service.unknownAltitudeCount > 0 { text.append("\(service.unknownAltitudeCount) zones have unconfirmed AGL limits.") }
            if service.omittedGeometryCount > 0 { text.append("\(service.omittedGeometryCount) zones have unsupported geometry.") }
        } else if text.isEmpty {
            text.append("No geozones loaded.")
        }
        return text.joined(separator: "\n")
    }

    private func importFile(_ service: DroneguideService) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, UTType(filenameExtension: "geojson") ?? .json]
        if panel.runModal() == .OK, let file = panel.url {
            Task { await service.importFile(file) }
        }
    }

    private func showBelgium(_ service: DroneguideService) {
        service.showLayer = true
        openWindow(id: OrecchinoApp.mainWindowId)
        model.focus(on: [CLLocationCoordinate2D(latitude: 49.4, longitude: 2.5),
                         CLLocationCoordinate2D(latitude: 51.6, longitude: 6.5)])
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor struct DroneguideMapCard: View {
    let zones: [DroneguideZone]
    let service: DroneguideService
    let now: Date
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Droneguide", systemImage: "map")
                    .foregroundStyle(droneguideColor)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Close Droneguide zones")
            }
            .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(zones) { zone in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(zone.name).font(.subheadline.weight(.semibold))
                            Text(status(service.activity(for: zone, at: now)))
                                .foregroundStyle(droneguideColor)
                            if !zone.restriction.isEmpty { Text(restriction(zone.restriction)) }
                            if let limits = limits(zone) { Text(limits).foregroundStyle(.secondary) }
                            ForEach(Array([zone.reason, zone.message, zone.schedule]
                                .filter { !$0.isEmpty }.enumerated()), id: \.offset) { item in
                                Text(item.element).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.trailing, 4)
            }
            .frame(maxHeight: 250)
            Link("Check zone conditions on Droneguide", destination: DroneguideWFS.website)
        }
        .font(.caption)
        .padding(12)
        .frame(width: 285)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func status(_ value: DroneguideActivity) -> String {
        switch value {
        case .active: return "Active"
        case .planned: return "Planned"
        case .inactive: return "Inactive"
        case .unknown: return "Status unconfirmed"
        }
    }

    private func restriction(_ value: String) -> String {
        switch value {
        case "REQ_AUTHORISATION": return "Authorisation required"
        case "PROHIBITED": return "Prohibited"
        case "CONDITIONAL": return "Conditional"
        default: return value
        }
    }

    private func limits(_ zone: DroneguideZone) -> String? {
        func height(_ value: Double?, _ unit: String, _ reference: String) -> String? {
            guard let value else { return nil }
            return [value.formatted(), unit, reference].filter { !$0.isEmpty }.joined(separator: " ")
        }
        let low = height(zone.lower, zone.lowerUnit, zone.lowerReference)
        let high = height(zone.upper, zone.upperUnit, zone.upperReference)
        guard low != nil || high != nil else { return nil }
        return "\(low ?? "—") – \(high ?? "—")"
    }
}
