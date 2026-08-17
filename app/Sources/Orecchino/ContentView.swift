import SwiftUI
import MapKit
import CoreLocation

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 270, ideal: 310, max: 400)
        } detail: {
            MapPane()
        }
        .navigationTitle("Orecchino")
        .toolbar {
            ToolbarItemGroup {
                ConnectionBadge()
                PortMenu()
                Toggle(isOn: $model.showTFR) {
                    Label("TFR", systemImage: "exclamationmark.triangle")
                }
                .help("Show FAA Temporary Flight Restrictions")
                Toggle(isOn: $model.followAll) {
                    Label("Follow", systemImage: "scope")
                }
                .help("Keep the map fitted to all drones")
                Toggle(isOn: $model.demoMode) {
                    Label("Demo", systemImage: "sparkles")
                }
                .help("Inject two simulated drones")
                Menu {
                    Button("Sync Map Tiles to Receiver") { model.tileSync.start() }
                    if let l = model.tileSync.phase.label { Text(l) }
                } label: {
                    Label("Device", systemImage: "square.and.arrow.down.on.square")
                }
                .help("Download map tiles and push them to the receiver's screen")
            }
        }
    }
}

// MARK: - Toolbar pieces

struct ConnectionBadge: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.serialStatus.isConnected ? Theme.ok : Theme.warn)
                .frame(width: 8, height: 8)
            Text(model.serialStatus.label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct PortMenu: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let ports = SerialManager.candidatePorts()
        Menu {
            Button("Auto-detect") { model.selectPort(nil) }
            Divider()
            ForEach(ports, id: \.self) { p in
                Button(p) { model.selectPort(p) }
            }
            if ports.isEmpty { Text("No serial ports found") }
        } label: {
            Label("Port", systemImage: "cable.connector")
        }
        .menuIndicator(.visible)
    }
}

// MARK: - Formatting

func fmtAge(_ s: TimeInterval) -> String {
    if s < 0 { return "0 s" }
    if s < 60 { return "\(Int(s)) s" }
    if s < 3600 { return "\(Int(s) / 60) m \(Int(s) % 60) s" }
    return String(format: "%.1f h", s / 3600)
}

func fmtDist(_ m: Double) -> String {
    m >= 1000 ? String(format: "%.1f km", m / 1000) : "\(Int(m)) m"
}

/// RSSI → 0…1 over a practical Remote ID window (−95 … −35 dBm).
func rssiStrength(_ rssi: Int) -> Double {
    min(1, max(0, (Double(rssi) + 95) / 60))
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section("Drones — \(model.trackList.count)") {
                ForEach(model.trackList) { t in
                    DroneRow(track: t)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.selection = (model.selection == t.id) ? nil : t.id
                        }
                        .listRowBackground(RowBackground(selected: model.selection == t.id,
                                                         color: t.color))
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.trackList.isEmpty {
                ContentUnavailableView {
                    Label("No drones", systemImage: "antenna.radiowaves.left.and.right")
                } description: {
                    Text(model.serialStatus.isConnected
                         ? "Listening for Remote ID…"
                         : "Waiting for the receiver…")
                }
            }
        }
    }
}

/// Selection: inset left accent bar plus a tint — reads even in greyscale.
struct RowBackground: View {
    let selected: Bool
    let color: Color
    var body: some View {
        if selected {
            HStack(spacing: 0) {
                Rectangle().fill(color).frame(width: 3)
                color.opacity(0.10)
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }
}

struct DroneRow: View {
    @Environment(AppModel.self) private var model
    let track: DroneTrack

    private var age: TimeInterval { model.now.timeIntervalSince(track.lastSeen) }
    private var isStale: Bool { age > AppModel.staleAfter }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(track.color.opacity(0.18)).frame(width: 34, height: 34)
                Image(systemName: "airplane")
                    .font(.system(size: 15))
                    .foregroundStyle(isStale ? Theme.staleInk : track.color)
                    .rotationEffect(.degrees((track.heading ?? 0) - 90))
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(track.title)
                        .font(.system(.body, design: .monospaced).weight(.medium))
                        .lineLimit(1)
                    if isStale {
                        Text("stale")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.staleInk)
                    }
                }
                // Recent-activity micro-bar: decays to zero over 3 s.
                RecencyBar(fraction: max(0, 1 - age / 3), color: track.color)
                HStack(spacing: 6) {
                    ForEach(track.sources.sorted(), id: \.self) { s in
                        SourceBadge(text: s.uppercased(), color: track.color)
                    }
                    if track.phy == "coded" {
                        SourceBadge(text: "LR", color: Theme.accent)
                    }
                    Text("\(track.rssi) dBm")
                        .font(.caption2).foregroundStyle(Theme.muted)
                    Text(RidNames.status(track.status))
                        .font(.caption2)
                        .foregroundStyle(track.status == 3 ? Theme.danger : Theme.muted)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let h = track.height {
                    Text("\(Int(h)) m").font(.caption.monospacedDigit())
                } else {
                    Text("—").font(.caption).foregroundStyle(Theme.unknown)
                }
                Text(fmtAge(age))
                    .font(.caption2.monospacedDigit()).foregroundStyle(Theme.muted)
            }
        }
        .opacity(isStale ? 0.55 : 1.0)
        .padding(.vertical, 2)
    }
}

struct SourceBadge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(color.opacity(0.22), in: Capsule())
    }
}

struct RecencyBar: View {
    let fraction: Double
    let color: Color
    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.06))
            Capsule().fill(color.opacity(0.85))
                .frame(width: max(0, 40 * fraction))
        }
        .frame(width: 40, height: 4)
        .help("recent activity \(Int(fraction * 100))%")
    }
}

// MARK: - Map

struct MapPane: View {
    @Environment(AppModel.self) private var model
    // Hand-rolled @State: the CLT SDK is missing the SwiftUIMacros plugin.
    private let cameraState = State(initialValue: MapCameraPosition.automatic)
    private var camera: Binding<MapCameraPosition> { cameraState.projectedValue }
    private let lastFitState = State<MKCoordinateRegion?>(initialValue: nil)

    /// Fit the camera to all drone + operator positions. `.automatic` can't
    /// do this job: it frames ALL map content, and the TFR overlay spans the
    /// country, so it would zoom out to the whole US.
    private func refit(force: Bool) {
        guard model.followAll else { return }
        var coords = model.trackList.compactMap(\.coordinate)
        coords += model.trackList.compactMap(\.operatorCoord)
        guard !coords.isEmpty else { return }
        let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
        let center = CLLocationCoordinate2D(
            latitude: (lats.min()! + lats.max()!) / 2,
            longitude: (lons.min()! + lons.max()!) / 2)
        let latD = max((lats.max()! - lats.min()!) * 1.5, 0.02)
        let lonD = max((lons.max()! - lons.min()!) * 1.5, 0.02)
        let region = MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: latD, longitudeDelta: lonD))
        // Damping: skip refits that barely move the frame, so the camera
        // isn't perpetually animating under live position updates.
        if !force, let last = lastFitState.wrappedValue,
           abs(last.center.latitude - center.latitude) < latD * 0.06,
           abs(last.center.longitude - center.longitude) < lonD * 0.06,
           abs(last.span.latitudeDelta - latD) < latD * 0.12,
           abs(last.span.longitudeDelta - lonD) < lonD * 0.12 {
            return
        }
        lastFitState.wrappedValue = region
        withAnimation(.easeInOut(duration: 0.5)) {
            camera.wrappedValue = .region(region)
        }
    }

    var body: some View {
        Map(position: camera) {
            if model.showTFR {
                ForEach(model.tfr.zones) { z in
                    MapPolygon(coordinates: z.outerRing)
                        .foregroundStyle(Theme.danger.opacity(0.10))
                        .stroke(Theme.danger.opacity(0.55), lineWidth: 1.2)
                    Annotation("", coordinate: z.centroid, anchor: .center) {
                        TFRTag(zone: z)
                    }
                }
            }
            ForEach(model.trackList) { t in
                if let c = t.coordinate {
                    if t.trail.count > 1 {
                        MapPolyline(coordinates: t.trail)
                            .stroke(t.color.opacity(0.7),
                                    style: StrokeStyle(lineWidth: 2, lineCap: .round,
                                                       lineJoin: .round))
                    }
                    if let op = t.operatorCoord {
                        MapPolyline(coordinates: [c, op])
                            .stroke(t.color.opacity(0.45),
                                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
                        Annotation("", coordinate: op, anchor: .center) {
                            OperatorMarker(track: t)
                        }
                    }
                    Annotation("", coordinate: c, anchor: .center) {
                        DroneMarker(track: t,
                                    selected: model.selection == t.id,
                                    stale: model.now.timeIntervalSince(t.lastSeen) > 60)
                            .onTapGesture { model.selection = t.id }
                    }
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll,
                            showsTraffic: false))
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .overlay(alignment: .bottomLeading) {
            if let sel = model.selection, let t = model.tracks[sel] {
                DroneDetailCard(track: t)
                    .padding(12)
                    .padding(.bottom, 26)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let sel = model.selectedTFR,
               let z = model.tfr.zones.first(where: { $0.id == sel }) {
                TFRCard(zone: z)
                    .padding(12)
                    .padding(.bottom, 26)
            }
        }
        .overlay(alignment: .bottom) {
            StatusStrip()
        }
        .onChange(of: model.updateTick) { _, _ in
            refit(force: false)
        }
        .onChange(of: model.selection) { _, sel in
            guard let sel, let c = model.tracks[sel]?.coordinate else { return }
            model.followAll = false  // focusing one drone ends group-follow
            withAnimation(.easeInOut(duration: 0.6)) {
                camera.wrappedValue = .region(MKCoordinateRegion(
                    center: c, latitudinalMeters: 2000, longitudinalMeters: 2000))
            }
        }
        .onChange(of: model.followAll) { _, on in
            if on { refit(force: true) }
        }
        .onAppear {
            refit(force: true)
        }
        .onChange(of: camera.wrappedValue) { _, newValue in
            if newValue.positionedByUser, model.followAll {
                model.followAll = false
            }
        }
    }
}

struct TFRTag: View {
    @Environment(AppModel.self) private var model
    let zone: TFRZone
    var body: some View {
        Text("TFR")
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Theme.danger.opacity(0.30), in: Capsule())
            .overlay(Capsule().stroke(Theme.danger.opacity(0.6), lineWidth: 0.5))
            .foregroundStyle(.white)
            .onTapGesture {
                model.selectedTFR = (model.selectedTFR == zone.id) ? nil : zone.id
            }
    }
}

struct DroneMarker: View {
    let track: DroneTrack
    let selected: Bool
    let stale: Bool

    var body: some View {
        // Freshness overrides identity on the dot; the trail keeps the color.
        let ink = stale ? Theme.staleInk : track.color
        ZStack {
            Circle()
                .fill(.black.opacity(0.55))
                .frame(width: 30, height: 30)
                .overlay(Circle().stroke(ink, lineWidth: selected ? 2.5 : 1.2))
            Image(systemName: track.heading != nil ? "location.north.fill" : "circle.fill")
                .font(.system(size: track.heading != nil ? 14 : 8))
                .foregroundStyle(ink)
                .rotationEffect(.degrees(track.heading ?? 0))
        }
        .overlay(alignment: .bottom) {
            Text(track.title)
                .font(.system(size: 10, design: .monospaced))
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(.black.opacity(0.65), in: Capsule())
                .foregroundStyle(stale ? Theme.staleInk : .white)
                .fixedSize()
                .offset(y: 16)
        }
        .shadow(radius: 3)
    }
}

struct OperatorMarker: View {
    let track: DroneTrack
    var body: some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.55))
                .frame(width: 22, height: 22)
                .overlay(Circle().stroke(track.color.opacity(0.8), lineWidth: 1))
            Image(systemName: "person.fill")
                .font(.system(size: 10))
                .foregroundStyle(track.color.opacity(0.9))
        }
        .shadow(radius: 2)
    }
}

// MARK: - Drone detail card

struct DroneDetailCard: View {
    @Environment(AppModel.self) private var model
    let track: DroneTrack

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(track.color).frame(width: 8, height: 8)
                Text(track.title)
                    .font(.system(.headline, design: .monospaced))
                    .lineLimit(1)
                Spacer(minLength: 12)
                Text(RidNames.uaType(track.uaType))
                    .font(.caption).foregroundStyle(Theme.muted)
            }

            VitalsGrid(track: track)

            KVSection(title: "Identity") {
                KVRow(name: "UAS ID", value: track.uasId)
                KVRow(name: "ID type", value: track.idType.map { RidNames.idType($0) })
                KVRow(name: "Evidence", value: track.evidence,
                      help: "B basic · L location · S self-ID · Y system · O operator")
                KVRow(name: "MAC", value: track.macs.sorted().joined(separator: " "))
            }
            KVSection(title: "Position") {
                KVRow(name: "Lat, Lon", value: track.coordinate.map {
                    String(format: "%.6f, %.6f", $0.latitude, $0.longitude) })
                KVRow(name: "Alt geo", value: track.altGeo.map { "\(Int($0)) m" })
                KVRow(name: "Alt baro", value: track.altBaro.map { "\(Int($0)) m" })
                KVRow(name: "Heading", value: track.heading.map { "\(Int($0))°" })
                KVRow(name: "Climb", value: track.vspeed.map {
                    String(format: "%+.1f m/s", $0) })
                KVRow(name: "Status", value: RidNames.status(track.status),
                      ink: track.status == 3 ? Theme.danger : nil)
            }
            KVSection(title: "Operator") {
                KVRow(name: "Operator", value: track.operatorId)
                KVRow(name: "Position", value: track.operatorCoord.map {
                    String(format: "%.6f, %.6f", $0.latitude, $0.longitude) })
                KVRow(name: "Alt", value: track.operatorAlt.map { "\(Int($0)) m" })
                KVRow(name: "Self ID", value: track.selfDesc)
                if let d = track.operatorDistance, d > 15_000 {
                    KVRow(name: "Spoof?", value: "operator \(fmtDist(d)) away",
                          ink: Theme.warn,
                          help: "Drone and operator are implausibly far apart")
                }
            }

            HStack {
                Text("\(track.msgCount) msgs")
                Spacer()
                Text("first seen \(fmtAge(model.now.timeIntervalSince(track.firstSeen))) ago")
            }
            .font(.system(size: 9.5, design: .monospaced))
            .foregroundStyle(Theme.muted)
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Color.white.opacity(0.06), lineWidth: 1))
    }
}

/// Six highest-value fields, redundantly summarized above the full list.
struct VitalsGrid: View {
    @Environment(AppModel.self) private var model
    let track: DroneTrack

    var body: some View {
        let link = track.sources.sorted().map(\.localizedUppercase)
            .joined(separator: "+")
            + (track.phy == "coded" ? " LR" : "")
        Grid(horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                VitalCell(label: "RSSI", value: "\(track.rssi)", unit: "dBm") {
                    RssiBar(strength: rssiStrength(track.rssi))
                }
                VitalCell(label: "HEIGHT",
                          value: track.height.map { "\(Int($0))" }, unit: "m")
                VitalCell(label: "SPEED",
                          value: track.speed.map { String(format: "%.1f", $0) },
                          unit: "m/s")
            }
            GridRow {
                VitalCell(label: "OP DIST",
                          value: track.operatorDistance.map { fmtDist($0) }, unit: nil)
                VitalCell(label: "AGE",
                          value: fmtAge(model.now.timeIntervalSince(track.lastSeen)),
                          unit: nil)
                VitalCell(label: "LINK", value: link.isEmpty ? nil : link, unit: nil)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 7))
    }
}

struct VitalCell<Extra: View>: View {
    let label: String
    let value: String?
    let unit: String?
    @ViewBuilder var extra: Extra

    init(label: String, value: String?, unit: String?,
         @ViewBuilder extra: () -> Extra = { EmptyView() }) {
        self.label = label
        self.value = value
        self.unit = unit
        self.extra = extra()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 8.5, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(Theme.muted)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                // Absent values look absent: dimmed em-dash, never a fake zero.
                Text(value ?? "—")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(value == nil ? Theme.unknown : Color.primary)
                    .lineLimit(1)
                if value != nil, let unit {
                    Text(unit).font(.system(size: 9))
                        .foregroundStyle(Theme.muted)
                }
            }
            extra
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(value == nil ? "not received yet" : "")
    }
}

struct RssiBar: View {
    let strength: Double
    var body: some View {
        let tint: Color = strength < 0.33 ? Theme.danger
                        : strength < 0.66 ? Theme.warn : Theme.ok
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.07))
            Capsule().fill(tint).frame(width: max(2, 56 * strength))
        }
        .frame(width: 56, height: 3)
    }
}

struct KVSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .kerning(1.0)
                .foregroundStyle(Theme.accent)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                content
            }
        }
    }
}

struct KVRow: View {
    let name: String
    let value: String?
    var ink: Color?
    var help: String?

    init(name: String, value: String?, ink: Color? = nil, help: String? = nil) {
        self.name = name
        self.value = value
        self.ink = ink
        self.help = help
    }

    var body: some View {
        GridRow {
            Text(name)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.muted)
                .gridColumnAlignment(.trailing)
            Text(value?.isEmpty == false ? value! : "—")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(value?.isEmpty == false ? (ink ?? Color.primary)
                                                         : Theme.unknown)
                .textSelection(.enabled)
                .help(help ?? (value?.isEmpty != false ? "not received yet" : ""))
        }
    }
}

// MARK: - TFR card

struct TFRCard: View {
    @Environment(AppModel.self) private var model
    let zone: TFRZone

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.danger)
                Text("TFR \(zone.notam)")
                    .font(.system(.headline, design: .monospaced))
                Spacer(minLength: 10)
                Button {
                    model.selectedTFR = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                KVRow(name: "Type", value: zone.legal, ink: Theme.danger)
                KVRow(name: "State", value: zone.state)
            }
            Text(zone.title)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Theme.danger.opacity(0.25), lineWidth: 1))
    }
}

// MARK: - Status strip

struct StatusStrip: View {
    @Environment(AppModel.self) private var model

    private var heartbeatOK: Bool {
        guard let hb = model.stats.lastHeartbeat else { return false }
        return model.now.timeIntervalSince(hb) < 6
    }

    var body: some View {
        HStack(spacing: 0) {
            Seg {
                Circle()
                    .fill(model.serialStatus.isConnected
                          ? (heartbeatOK ? Theme.ok : Theme.warn) : Theme.danger)
                    .frame(width: 6, height: 6)
                Text(model.serialStatus.isConnected
                     ? (heartbeatOK ? model.serialStatus.label : "no heartbeat")
                     : "no device")
            }
            divider
            Seg { Text("wifi \(model.stats.wifiFrames.formatted())") }
            divider
            Seg {
                Text("ble \(model.stats.bleAdvs.formatted())")
                Text(model.stats.bleOk ? (model.stats.bleExt ? "BT5" : "BT4") : "off")
                    .foregroundStyle(model.stats.bleOk ? Theme.accent : Theme.warn)
            }
            divider
            Seg {
                Text("rid \(model.stats.ridCount.formatted())")
                if model.stats.dropped > 0 {
                    Text("drop \(model.stats.dropped)").foregroundStyle(Theme.warn)
                }
            }
            divider
            Seg { Text("ch \(model.stats.channel)") }
            if let tl = model.tileSync.phase.label {
                divider
                Seg { Text(tl).foregroundStyle(Theme.accent) }
            }
            divider
            Seg {
                Text(model.tfr.status.label)
                    .foregroundStyle({
                        if case .failed = model.tfr.status { return Theme.warn }
                        return Theme.muted
                    }())
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(Theme.muted)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.06), lineWidth: 1))
        .padding(.bottom, 8)
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 12)
    }
}

struct Seg<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 5) { content }
            .padding(.horizontal, 10)
    }
}
