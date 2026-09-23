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
                    Button("Match Log…") { model.deviceLog.isPresented = true }
                    Divider()
                    Button("Sync Map Tiles to Receiver") { model.tileSync.start() }
                    if let l = model.tileSync.phase.label { Text(l) }
                } label: {
                    Label("Device", systemImage: "square.and.arrow.down.on.square")
                }
                .help("The receiver's match log, and map tiles for its screen")
            }
        }
        .sheet(isPresented: Bindable(model.deviceLog).isPresented) {
            DeviceLogView().environment(model)
        }
    }
}

// MARK: - Toolbar pieces

/// Colour and symbol per receiver-health state. The wording carries the
/// state as well, so no surface is colour-only.
extension ReceiverHealth {
    var tint: Color {
        switch self {
        case .searching:      return Theme.warn
        case .waitingForData: return Theme.muted
        case .receiving:      return Theme.ok
        case .stalled:        return Theme.warn
        }
    }
    var symbol: String {
        switch self {
        case .searching:      return "cable.connector"
        case .waitingForData: return "hourglass"
        case .receiving:      return "antenna.radiowaves.left.and.right"
        case .stalled:        return "antenna.radiowaves.left.and.right.slash"
        }
    }
}

struct ConnectionBadge: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let health = model.receiverHealth
        HStack(spacing: 6) {
            Circle()
                .fill(health.tint)
                .frame(width: 8, height: 8)
            Text(model.receiverStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .help(health.explanation)
    }
}

struct PortMenu: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let ports = SerialManager.candidatePorts()
        let connected: String? = {
            if case .connected(let p) = model.serialStatus { return p }
            return nil
        }()
        Menu {
            Button("Auto-detect") { model.selectPort(nil) }
            Divider()
            ForEach(ports, id: \.self) { p in
                Button { model.selectPort(p) } label: {
                    if p == connected {
                        Label(p, systemImage: "checkmark")
                    } else {
                        Text(p)
                    }
                }
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

/// Value and unit separately, for vital cells that size them differently.
func fmtDistParts(_ m: Double) -> (value: String, unit: String) {
    m >= 1000 ? (String(format: "%.1f", m / 1000), "km") : ("\(Int(m))", "m")
}

/// RSSI → 0…1 over a practical Remote ID window (−95 … −35 dBm).
func rssiStrength(_ rssi: Int) -> Double {
    min(1, max(0, (Double(rssi) + 95) / 60))
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        // Native list selection: arrow keys walk the list, clicks select,
        // and the selection pill takes each drone's identity color.
        List(selection: $model.selection) {
            Section(model.droneCountHeader) {
                ForEach(model.trackList) { t in
                    DroneRow(track: t)
                        .tag(t.id)
                        .listItemTint(t.color)
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.trackList.isEmpty { ReceiverEmptyState() }
        }
    }
}

/// Empty sidebar: says what the receiver is doing right now and, when no
/// port is open, puts the recovery actions inline instead of leaving them
/// to be discovered in the toolbar.
struct ReceiverEmptyState: View {
    @Environment(AppModel.self) private var model

    private var portBinding: Binding<String?> {
        Binding(get: { model.preferredPort }, set: { model.selectPort($0) })
    }

    var body: some View {
        let health = model.receiverHealth
        ContentUnavailableView {
            Label(health.title, systemImage: health.symbol)
        } description: {
            Text(health.explanation)
        } actions: {
            if health == .searching {
                let ports = SerialManager.candidatePorts()
                VStack(spacing: 8) {
                    Picker("Port", selection: portBinding) {
                        Text("Auto-detect").tag(String?.none)
                        ForEach(ports, id: \.self) { p in
                            Text((p as NSString).lastPathComponent).tag(String?.some(p))
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 230)
                    if ports.isEmpty {
                        Text("No serial ports found")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.muted)
                    }
                    Button("Retry auto-detect") { model.selectPort(nil) }
                }
                .padding(.top, 4)
            }
        }
    }
}

struct DroneRow: View {
    @Environment(AppModel.self) private var model
    let track: DroneTrack

    var body: some View {
        let age = model.age(of: track)
        let stale = model.isStale(track)
        let alerts = track.alerts
        let dim = stale ? 0.55 : 1.0
        HStack(alignment: .top, spacing: 8) {
            ZStack {
                Circle().fill(track.color.opacity(0.18)).frame(width: 30, height: 30)
                Image(systemName: "airplane")
                    .font(.system(size: 14))
                    .foregroundStyle(stale ? Theme.staleInk : track.color)
                    .rotationEffect(.degrees((track.heading ?? 0) - 90))
            }
            .opacity(dim)
            VStack(alignment: .leading, spacing: 3) {
                // Protected first line: the name may shrink (middle-truncated
                // so the distinguishing suffix survives) but an alert never
                // truncates and never dims.
                HStack(spacing: 6) {
                    Text(track.title)
                        .font(.system(size: 12.5, design: .monospaced).weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .opacity(dim)
                    if let first = alerts.first {
                        AlertTag(alert: first)
                            .fixedSize()
                            .layoutPriority(1)
                    }
                }
                if alerts.count > 1 {
                    TagFlow(spacing: 4) {
                        ForEach(alerts.dropFirst(), id: \.self) { a in
                            AlertTag(alert: a).fixedSize()
                        }
                    }
                }
                // Recent-activity micro-bar: decays to zero over 3 s.
                RecencyBar(fraction: max(0, 1 - age / 3), color: track.color)
                    .opacity(dim)
                RowMeta(manufacturer: track.model ?? track.manufacturer,
                        height: track.height.map { "\(Int($0)) m" },
                        heightRef: track.heightRefShort,
                        range: model.range(to: track).map { "range \(fmtDist($0))" },
                        lastHeard: "last heard \(fmtAge(age))",
                        color: track.color)
                    .opacity(dim)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Second row line. Candidates shed the manufacturer, then the height
/// reference, then wrap, so the readings themselves never truncate.
struct RowMeta: View {
    let manufacturer: String?
    let height: String?
    let heightRef: String?
    let range: String?
    let lastHeard: String
    let color: Color

    var body: some View {
        ViewThatFits(in: .horizontal) {
            line(mfr: true, ref: true)
            line(mfr: false, ref: true)
            line(mfr: false, ref: false)
            VStack(alignment: .leading, spacing: 2) {
                measures(ref: true)
                Text(lastHeard)
            }
        }
        .font(.system(size: 10.5).monospacedDigit())
        .foregroundStyle(Theme.muted)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func line(mfr: Bool, ref: Bool) -> some View {
        HStack(spacing: 5) {
            if mfr, let m = manufacturer {
                Text(m)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(color)
                dot
            }
            measures(ref: ref)
            dot
            Text(lastHeard)
        }
    }

    private func measures(ref: Bool) -> some View {
        HStack(spacing: 5) {
            if let height {
                if ref, let heightRef {
                    Text("\(height) \(heightRef)")
                } else {
                    Text(height)
                }
            } else {
                Text("— m").foregroundStyle(Theme.unknown)
            }
            if let range {
                dot
                Text(range)
            }
        }
    }

    private var dot: some View { Text("·") }
}

/// A badge that is never allowed to truncate: callers give it `.fixedSize()`
/// and let the neighbouring name shrink instead.
struct AlertTag: View {
    let alert: TrackAlert
    var body: some View {
        let color: Color = alert == .simulated ? Theme.warn : Theme.danger
        HStack(spacing: 3) {
            Image(systemName: alert.symbol)
                .font(.system(size: 8, weight: .bold))
            Text(alert.label)
                .font(.system(size: 9, weight: .bold))
                .kerning(0.1)
        }
        .lineLimit(1)
        .padding(.horizontal, 4).padding(.vertical, 2)
        .background(color.opacity(0.20), in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.7), lineWidth: 0.8))
        .foregroundStyle(color)
        .help(alert.help)
    }
}

/// Left-to-right flow of fixed-size tags that wraps instead of truncating.
struct TagFlow: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        let a = arrange(width: bounds.width, subviews: subviews)
        for (i, o) in a.origins.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + o.x, y: bounds.minY + o.y),
                              proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews)
        -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxW: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0, x + sz.width > width {
                x = 0
                y += rowH + spacing
                rowH = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
            maxW = max(maxW, x - spacing)
        }
        return (CGSize(width: maxW, height: y + rowH), origins)
    }
}

/// Authentication state. Deliberately says "ID" rather than a bare tick:
/// the signature covers the identity, never the reported position.
struct AuthBadge: View {
    let state: String
    var body: some View {
        let (text, color): (String, Color) = switch state {
        case "id_valid":    ("ID✓", Theme.ok)
        case "invalid":     ("ID✗", Theme.danger)
        case "partial":     ("ID…", Theme.muted)
        case "unknown_key": ("ID?", Theme.warn)
        default:            ("", Theme.muted)
        }
        if !text.isEmpty {
            Text(text)
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(color.opacity(0.22), in: Capsule())
                .foregroundStyle(color)
                .help("Authentication: \(state)")
        }
    }
}

struct SourceBadge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 1)
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

// MARK: - Map geometry (pure; unit-tested)

/// Camera fitting that knows which parts of the pane are covered by cards,
/// the banner and the status strip, so fitted content never lands under them.
enum MapFit {
    struct Insets: Equatable {
        var top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0
    }

    /// Bounding rect of `coords` in map points, grown by `margin` on each
    /// axis and never smaller than `minMeters` across.
    static func bounds(of coords: [CLLocationCoordinate2D], margin: Double,
                       minMeters: Double) -> MKMapRect {
        let pts = coords.map { MKMapPoint($0) }
        guard let first = pts.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in pts {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
        let lat = MKMapPoint(x: cx, y: cy).coordinate.latitude
        let minPts = MKMapPointsPerMeterAtLatitude(lat) * minMeters
        let w = max((maxX - minX) * margin, minPts)
        let h = max((maxY - minY) * margin, minPts)
        return MKMapRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    /// The visible map rect (same aspect as `frame`) that shows `content`
    /// centred in the part of the pane the insets leave uncovered.
    static func rect(content: MKMapRect, frame: CGSize, insets: Insets) -> MKMapRect {
        let availW = max(1, frame.width - insets.left - insets.right)
        let availH = max(1, frame.height - insets.top - insets.bottom)
        let scale = max(content.width / availW, content.height / availH)  // map pts per pt
        let cx = insets.left + availW / 2   // pixel centre of the uncovered area
        let cy = insets.top + availH / 2
        return MKMapRect(x: content.midX - cx * scale, y: content.midY - cy * scale,
                         width: frame.width * scale, height: frame.height * scale)
    }

    /// Damping: true when `b` barely differs from `a`, so live position
    /// updates don't keep the camera perpetually animating.
    static func close(_ a: MKMapRect, _ b: MKMapRect) -> Bool {
        abs(a.midX - b.midX) < b.width * 0.06 &&
        abs(a.midY - b.midY) < b.height * 0.06 &&
        abs(a.width - b.width) < b.width * 0.12 &&
        abs(a.height - b.height) < b.height * 0.12
    }
}

/// Label collision handling. SwiftUI's Map has no annotation-collision API,
/// so the pane projects each track to a point and decides here which labels
/// get drawn: the selected and alerting aircraft always, everyone else only
/// where the label covers neither another label nor another marker.
enum MapLabels {
    static let markerSize: CGFloat = 30
    static let labelHeight: CGFloat = 18
    /// Distance from the marker centre down to the top of its label.
    static let labelTop: CGFloat = 13

    /// Priorities, lowest first; `selected` and `alerting` are always shown.
    static let selected = 0, alerting = 1, fresh = 2, stale = 3

    /// Estimated capsule width: ~6.6 pt per monospaced character at 11 pt,
    /// the SIMULATED suffix, and the horizontal padding.
    static func labelWidth(title: String, simulated: Bool) -> CGFloat {
        CGFloat(title.count) * 6.6 + (simulated ? 54 : 0) + 10
    }
    static func labelRect(at p: CGPoint, width: CGFloat) -> CGRect {
        CGRect(x: p.x - width / 2, y: p.y + labelTop, width: width, height: labelHeight)
    }
    static func markerRect(at p: CGPoint) -> CGRect {
        CGRect(x: p.x - markerSize / 2, y: p.y - markerSize / 2,
               width: markerSize, height: markerSize)
    }

    static func visibleLabels(points: [(id: String, point: CGPoint, priority: Int,
                                        width: CGFloat)]) -> Set<String> {
        let ordered = points.enumerated()
            .sorted { ($0.element.priority, $0.offset) < ($1.element.priority, $1.offset) }
            .map(\.element)
        var placed: [CGRect] = []
        var visible = Set<String>()
        for p in ordered {
            let r = labelRect(at: p.point, width: p.width)
            let forced = p.priority <= alerting
            let blocked = placed.contains { $0.intersects(r) }
                || points.contains { $0.id != p.id && markerRect(at: $0.point).intersects(r) }
            if forced || !blocked {
                visible.insert(p.id)
                placed.append(r)
            }
        }
        return visible
    }
}

// MARK: - Map

struct MapPane: View {
    @Environment(AppModel.self) private var model
    // Hand-rolled @State: the CLT SDK is missing the SwiftUIMacros plugin.
    private let cameraState = State(initialValue: MapCameraPosition.automatic)
    private var camera: Binding<MapCameraPosition> { cameraState.projectedValue }
    private let lastFitState = State<MKMapRect?>(initialValue: nil)
    /// Labels that fit; nil until the first projection, when all are shown.
    private let visibleLabelsState = State<Set<String>?>(initialValue: nil)

    static let cardWidth: CGFloat = 320
    static let tfrCardWidth: CGFloat = 280
    static let bannerHeight: CGFloat = 28
    static let stripHeight: CGFloat = 44

    private var droneCard: DroneTrack? {
        guard let sel = model.selection else { return nil }
        return model.tracks[sel]
    }
    private var tfrCard: TFRZone? {
        guard let sel = model.selectedTFR else { return nil }
        return model.tfr.zones.first(where: { $0.id == sel })
    }
    /// Parts of the pane covered by the banner, the strip and whichever
    /// card is up (the model keeps the two cards mutually exclusive).
    private var insets: MapFit.Insets {
        var i = MapFit.Insets(top: model.demoMode ? Self.bannerHeight : 0,
                              bottom: Self.stripHeight)
        if droneCard != nil {
            i.left = Self.cardWidth + 24
        } else if tfrCard != nil {
            i.right = Self.tfrCardWidth + 24
        }
        return i
    }
    /// Selected track last, so its marker draws above the others.
    private var orderedTracks: [DroneTrack] {
        let sel = model.selection
        return model.trackList.filter { $0.id != sel } + model.trackList.filter { $0.id == sel }
    }

    /// Fit the camera to all drone + operator positions. `.automatic` can't
    /// do this job: it frames ALL map content, and the TFR overlay spans the
    /// country, so it would zoom out to the whole US.
    private func refit(force: Bool, size: CGSize) {
        guard model.followAll, size.width > 0, size.height > 0 else { return }
        var coords = model.trackList.compactMap(\.coordinate)
        coords += model.trackList.compactMap(\.operatorCoord)
        guard !coords.isEmpty else { return }
        let content = MapFit.bounds(of: coords, margin: 1.4, minMeters: 2200)
        let rect = MapFit.rect(content: content, frame: size, insets: insets)
        if !force, let last = lastFitState.wrappedValue, MapFit.close(last, rect) { return }
        lastFitState.wrappedValue = rect
        withAnimation(.easeInOut(duration: 0.5)) {
            camera.wrappedValue = .rect(rect)
        }
    }

    /// Centre one aircraft in the part of the pane the card leaves free.
    private func focus(on c: CLLocationCoordinate2D, size: CGSize) {
        let content = MapFit.bounds(of: [c], margin: 1, minMeters: 2000)
        let rect = MapFit.rect(content: content, frame: size, insets: insets)
        withAnimation(.easeInOut(duration: 0.6)) {
            camera.wrappedValue = .rect(rect)
        }
    }

    private func recomputeLabels(_ proxy: MapProxy) {
        var pts: [(id: String, point: CGPoint, priority: Int, width: CGFloat)] = []
        for t in model.trackList {
            guard let c = t.coordinate, let p = proxy.convert(c, to: .local) else { continue }
            let pri = model.selection == t.id ? MapLabels.selected
                    : t.isAlerting ? MapLabels.alerting
                    : model.isStale(t) ? MapLabels.stale : MapLabels.fresh
            pts.append((t.id, p, pri, MapLabels.labelWidth(title: t.title, simulated: t.isDemo)))
        }
        let vis = MapLabels.visibleLabels(points: pts)
        if visibleLabelsState.wrappedValue != vis { visibleLabelsState.wrappedValue = vis }
    }

    var body: some View {
        GeometryReader { geo in
            MapReader { proxy in
                let visible = visibleLabelsState.wrappedValue
                Map(position: camera) {
                    if model.showTFR {
                        ForEach(model.tfr.zones) { z in
                            MapPolygon(coordinates: z.outerRing)
                                .foregroundStyle(Theme.danger.opacity(0.10))
                                .stroke(Theme.danger.opacity(0.55), lineWidth: 1.2)
                            Annotation("", coordinate: z.centroid, anchor: .center) {
                                TFRTag(zone: z)
                                    .environment(model)
                            }
                        }
                    }
                    ForEach(orderedTracks) { t in
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
                                        .environment(model)
                                }
                            }
                            Annotation("", coordinate: c, anchor: .center) {
                                DroneMarker(track: t,
                                            selected: model.selection == t.id,
                                            stale: model.isStale(t),
                                            showLabel: visible?.contains(t.id) ?? true)
                                    .onTapGesture { model.selection = t.id }
                                    .environment(model)
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
                .onMapCameraChange(frequency: .continuous) { _ in
                    recomputeLabels(proxy)
                }
                .onChange(of: model.updateTick) { _, _ in
                    refit(force: false, size: geo.size)
                    recomputeLabels(proxy)
                }
                .onChange(of: model.now) { _, _ in
                    // Freshness flips change a label's priority.
                    recomputeLabels(proxy)
                }
                .onChange(of: model.selection) { _, sel in
                    recomputeLabels(proxy)
                    guard let sel, let c = model.tracks[sel]?.coordinate else { return }
                    model.followAll = false  // focusing one drone ends group-follow
                    focus(on: c, size: geo.size)
                }
                .onChange(of: model.followAll) { _, on in
                    if on { refit(force: true, size: geo.size) }
                }
                .onAppear {
                    refit(force: true, size: geo.size)
                }
                .onChange(of: camera.wrappedValue) { _, newValue in
                    if newValue.positionedByUser, model.followAll {
                        model.followAll = false
                    }
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let t = droneCard {
                    DroneDetailCard(track: t,
                                    maxHeight: min(460, max(240, geo.size.height * 0.6)))
                        .padding(12)
                        .padding(.bottom, 26)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let z = tfrCard {
                    TFRCard(zone: z)
                        .padding(12)
                        .padding(.bottom, 26)
                }
            }
            .overlay(alignment: .bottom) {
                StatusStrip()
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if model.demoMode {
                    SimulationBanner(count: model.simulatedCount)
                }
            }
        }
    }
}

/// Full-width amber bar across the top of the map while demo mode is on,
/// so a screenshot can never pass simulated aircraft off as real ones.
struct SimulationBanner: View {
    let count: Int
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(AppModel.simulationBanner(count: count))
                .kerning(0.6)
            Spacer(minLength: 8)
            Text("Demo toggle in the toolbar turns it off")
                .fontWeight(.regular)
                .opacity(0.8)
                .lineLimit(1)
        }
        .font(.system(size: 11.5, weight: .bold))
        .foregroundStyle(.black)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: MapPane.bannerHeight)
        .background(Theme.warn)
    }
}

struct TFRTag: View {
    @Environment(AppModel.self) private var model: AppModel?
    let zone: TFRZone
    var body: some View {
        Text("TFR")
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Theme.danger.opacity(0.30), in: Capsule())
            .overlay(Capsule().stroke(Theme.danger.opacity(0.6), lineWidth: 0.5))
            .foregroundStyle(.white)
            .onTapGesture {
                let m = model ?? AppModel.shared
                m.selectedTFR = (m.selectedTFR == zone.id) ? nil : zone.id
            }
    }
}

struct DroneMarker: View {
    let track: DroneTrack
    let selected: Bool
    let stale: Bool
    let showLabel: Bool

    var body: some View {
        // Freshness overrides identity on the dot; the trail keeps the color.
        let ink = stale ? Theme.staleInk : track.color
        let emergency = track.isEmergency
        let invalid = track.isAuthInvalid
        ZStack {
            // Alert rings sit outside the dot: a thick solid ring for an
            // emergency, a dashed ring for a failed ID signature, both when
            // both. The shape carries the distinction, not only the red.
            if invalid {
                Circle()
                    .stroke(Theme.danger, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                    .frame(width: emergency ? 42 : 36, height: emergency ? 42 : 36)
            }
            if emergency {
                Circle()
                    .stroke(Theme.danger, lineWidth: 3)
                    .frame(width: 36, height: 36)
            }
            Circle()
                .fill(.black.opacity(0.55))
                .frame(width: MapLabels.markerSize, height: MapLabels.markerSize)
                .overlay(Circle().stroke(ink, lineWidth: selected ? 2.5 : 1.2))
            Image(systemName: track.heading != nil ? "location.north.fill" : "circle.fill")
                .font(.system(size: track.heading != nil ? 14 : 8))
                .foregroundStyle(ink)
                .rotationEffect(.degrees(track.heading ?? 0))
        }
        .frame(width: MapLabels.markerSize, height: MapLabels.markerSize)
        .overlay(alignment: .topTrailing) {
            if emergency { AlertGlyph(alert: .emergency).offset(x: 9, y: -9) }
        }
        .overlay(alignment: .topLeading) {
            if invalid { AlertGlyph(alert: .authInvalid).offset(x: -9, y: -9) }
        }
        .overlay(alignment: .bottom) {
            if showLabel {
                HStack(spacing: 4) {
                    Text(track.title)
                    if track.isDemo {
                        Text("SIMULATED")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(Theme.warn)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(.black.opacity(0.65), in: Capsule())
                .foregroundStyle(stale ? Theme.staleInk : .white)
                .fixedSize()
                .offset(y: 16)
            }
        }
        .shadow(radius: 3)
    }
}

/// Filled red glyph on a marker: a triangle for an emergency, a crossed
/// shield for a failed ID signature. Distinct shapes, not just colour.
struct AlertGlyph: View {
    let alert: TrackAlert
    var body: some View {
        Image(systemName: alert.symbol)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Theme.danger)
            .shadow(color: .black.opacity(0.9), radius: 1.5)
            .help(alert.help)
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

struct CardBodyHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct DroneDetailCard: View {
    @Environment(AppModel.self) private var model
    let track: DroneTrack
    /// Hard ceiling on the card's height; the body scrolls beyond it.
    let maxHeight: CGFloat
    // Hand-rolled @State (see MapPane).
    private let techExpanded = State(initialValue: false)
    private let bodyHeight = State<CGFloat>(initialValue: 10_000)

    var body: some View {
        let age = model.age(of: track)
        // Header (+ alert strip) stays put; everything else scrolls.
        let chrome: CGFloat = 24 + 22 + 8 + (track.isAlerting ? 52 : 0)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(track.color).frame(width: 9, height: 9)
                Text(track.title)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if track.isDemo {
                    AlertTag(alert: .simulated).fixedSize().layoutPriority(1)
                }
                Spacer(minLength: 8)
                Text(RidNames.uaType(track.uaType))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .fixedSize()
                Button {
                    model.selection = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            if track.isAlerting {
                AlertStrip(alerts: track.alerts.filter { $0 != .simulated })
            }

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    VitalsGrid(track: track, age: age, range: model.range(to: track))

                    KVSection(title: "Identity") {
                        KVRow(name: "UAS ID", value: track.uasId)
                        KVRow(name: "Model", value: track.model ?? track.manufacturer,
                              help: "From the CTA-2063-A serial: the maker's 4-character code, "
                                  + "and for DJI the 3-character model code after it (local table)")
                        if track.ssidMismatch {
                            KVRow(name: "SSID?", value: "names a different serial",
                                  ink: Theme.warn,
                                  help: "The beacon's SSID carries RID- plus a serial that is not "
                                      + "the one in the Basic ID message: the broadcast disagrees "
                                      + "with itself")
                        }
                        KVRow(name: "ID type", value: track.idType.map { RidNames.idType($0) })
                        KVRow(name: "Auth", value: RidNames.authLabel(track.authState),
                              ink: track.authState == "invalid" ? Theme.danger
                                 : track.authState == "id_valid" ? Theme.ok : nil,
                              help: "Signed Authentication messages. id_valid means the "
                                  + "drone's ID was signed by a trusted key — the "
                                  + "position is not signed.")
                        KVRow(name: "Operator", value: track.operatorId)
                        KVRow(name: "Self ID", value: track.selfDesc)
                    }
                    KVSection(title: "Position (reported)") {
                        KVRow(name: "Lat, Lon", value: track.coordinate.map {
                            String(format: "%.6f, %.6f", $0.latitude, $0.longitude) })
                        KVRow(name: "Alt geo", value: track.altGeo.map { "\(Int($0)) m" })
                        KVRow(name: "Alt baro", value: track.altBaro.map { "\(Int($0)) m" })
                        KVRow(name: "Heading", value: track.heading.map { "\(Int($0))°" })
                        KVRow(name: "Climb", value: track.vspeed.map {
                            String(format: "%+.1f m/s", $0) })
                    }
                    KVSection(title: "Operator (reported)") {
                        KVRow(name: "Position", value: track.operatorCoord.map {
                            String(format: "%.6f, %.6f", $0.latitude, $0.longitude) })
                        KVRow(name: "Alt", value: track.operatorAlt.map { "\(Int($0)) m" })
                        if let d = track.operatorDistance, d > 15_000 {
                            KVRow(name: "Spoof?", value: "operator \(fmtDist(d)) away",
                                  ink: Theme.warn,
                                  help: "Drone and operator are implausibly far apart")
                        }
                    }

                    DisclosureGroup(isExpanded: techExpanded.projectedValue) {
                        TechnicalDetails(
                            track: track,
                            firstSeen: fmtAge(model.now.timeIntervalSince(track.firstSeen)))
                            .padding(.top, 4)
                    } label: {
                        Text("Technical details")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
                .background(GeometryReader { g in
                    Color.clear.preference(key: CardBodyHeightKey.self, value: g.size.height)
                })
            }
            .frame(height: min(bodyHeight.wrappedValue, max(100, maxHeight - chrome)))
            .onPreferenceChange(CardBodyHeightKey.self) { bodyHeight.wrappedValue = $0 }
        }
        .padding(12)
        .frame(width: MapPane.cardWidth, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Color.white.opacity(0.06), lineWidth: 1))
    }
}

/// Full-width alert block under the card header: one line per alert, each
/// with its own symbol, never truncated.
struct AlertStrip: View {
    let alerts: [TrackAlert]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(alerts, id: \.self) { a in
                HStack(spacing: 6) {
                    Image(systemName: a.symbol)
                    Text(a.label).kerning(0.5)
                }
                .help(a.help)
            }
        }
        .font(.system(size: 11.5, weight: .bold))
        .foregroundStyle(Theme.danger)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.danger.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .stroke(Theme.danger.opacity(0.5), lineWidth: 1))
    }
}

/// The six readings that matter first: what the aircraft says it is doing,
/// when it was last heard, how far away it is, how high, how fast, and how
/// far it is from its own operator. Everything technical lives further down.
struct VitalsGrid: View {
    let track: DroneTrack
    let age: TimeInterval
    let range: Double?

    var body: some View {
        let rangeParts = range.map { fmtDistParts($0) }
        let opParts = track.operatorDistance.map { fmtDistParts($0) }
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                VitalCell(label: "STATUS",
                          value: track.status.map { RidNames.status($0) }, unit: nil,
                          ink: track.isEmergency ? Theme.danger : nil,
                          help: "Operational status as broadcast by the aircraft",
                          numeric: false)
                VitalCell(label: "LAST HEARD", value: fmtAge(age), unit: "ago")
            }
            GridRow {
                VitalCell(label: "RANGE", value: rangeParts?.value, unit: rangeParts?.unit,
                          help: range == nil ? "needs this Mac's location"
                                             : "Distance from this Mac to the aircraft")
                VitalCell(label: track.heightLabel,
                          value: track.height.map { "\(Int($0))" }, unit: "m",
                          help: "Height as reported by the aircraft")
            }
            GridRow {
                VitalCell(label: "SPEED",
                          value: track.speed.map { String(format: "%.1f", $0) },
                          unit: "m/s")
                VitalCell(label: "AIRCRAFT–OPERATOR", value: opParts?.value,
                          unit: opParts?.unit,
                          help: "Distance between the aircraft and the operator position "
                              + "it reports — not the range from here")
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
    let ink: Color?
    let help: String?
    /// Numbers get the large monospaced treatment; words get a smaller
    /// proportional bold that may wrap to two lines.
    let numeric: Bool
    let extra: Extra

    init(label: String, value: String?, unit: String?, ink: Color? = nil,
         help: String? = nil, numeric: Bool = true,
         @ViewBuilder extra: () -> Extra = { EmptyView() }) {
        self.label = label
        self.value = value
        self.unit = unit
        self.ink = ink
        self.help = help
        self.numeric = numeric
        self.extra = extra()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                // Absent values look absent: dimmed em-dash, never a fake zero.
                Text(value ?? "—")
                    .font(numeric ? .system(size: 17, weight: .bold, design: .monospaced)
                                  : .system(size: 13, weight: .bold))
                    .foregroundStyle(value == nil ? Theme.unknown : (ink ?? Color.primary))
                    .lineLimit(numeric ? 1 : 2)
                    .fixedSize(horizontal: false, vertical: true)
                if value != nil, let unit {
                    Text(unit).font(.system(size: 10.5))
                        .foregroundStyle(Theme.muted)
                }
            }
            extra
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(help ?? (value == nil ? "not received yet" : ""))
    }
}

/// Signal strength is information, not a warning: accent when usable,
/// muted when weak. Red is reserved for states that need action.
struct RssiBar: View {
    let strength: Double
    var body: some View {
        let tint: Color = strength < 0.33 ? Theme.muted : Theme.accent
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.07))
            Capsule().fill(tint).frame(width: max(2, 56 * strength))
        }
        .frame(width: 56, height: 4)
    }
}

/// Everything a technician wants and nobody else needs: radio link,
/// signal, addresses, decode evidence, counters.
struct TechnicalDetails: View {
    let track: DroneTrack
    let firstSeen: String

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
            GridRow {
                Text("RSSI")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.muted)
                    .gridColumnAlignment(.trailing)
                HStack(spacing: 8) {
                    Text("\(track.rssi) dBm")
                        .font(.system(size: 11.5, design: .monospaced))
                    RssiBar(strength: rssiStrength(track.rssi))
                }
            }
            GridRow {
                Text("Link")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.muted)
                    .gridColumnAlignment(.trailing)
                HStack(spacing: 4) {
                    ForEach(track.sources.sorted(), id: \.self) { s in
                        SourceBadge(text: s.uppercased(), color: track.color)
                    }
                    if track.phy == "coded" {
                        SourceBadge(text: "LR", color: Theme.accent)
                    }
                    if let a = track.authState, a != "none" {
                        AuthBadge(state: a)
                    }
                    if track.sources.isEmpty {
                        Text("—").font(.system(size: 11.5)).foregroundStyle(Theme.unknown)
                    }
                }
            }
            KVRow(name: "PHY", value: track.phy)
            KVRow(name: "Format", value: track.format)
            KVRow(name: "SSID", value: track.ssid)
            KVRow(name: "Channel", value: track.channel.map { "\($0)" })
            KVRow(name: "MAC", value: track.macs.sorted().joined(separator: " "))
            KVRow(name: "Evidence", value: track.evidence,
                  help: "B basic · L location · S self-ID · Y system · O operator")
            KVRow(name: "Messages", value: "\(track.msgCount)")
            KVRow(name: "First seen", value: "\(firstSeen) ago")
            KVRow(name: "Track key", value: track.id)
        }
    }
}

struct KVSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .kerning(1.0)
                .foregroundStyle(Theme.accent)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
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
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.muted)
                .gridColumnAlignment(.trailing)
            Text(value?.isEmpty == false ? value! : "—")
                .font(.system(size: 11.5, design: .monospaced))
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
                .help("Close")
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                KVRow(name: "Type", value: zone.legal, ink: Theme.danger)
                KVRow(name: "State", value: zone.state)
            }
            Text(zone.title)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: MapPane.tfrCardWidth, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Theme.danger.opacity(0.25), lineWidth: 1))
    }
}

// MARK: - Status strip

struct StatusStrip: View {
    @Environment(AppModel.self) private var model

    private var deviceHelp: String {
        var parts: [String] = [model.receiverHealth.explanation]
        if let f = model.stats.firmware { parts.append("firmware \(f)") }
        if model.stats.uptimeMs > 0 {
            parts.append("up \(fmtAge(Double(model.stats.uptimeMs) / 1000))")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let health = model.receiverHealth
        HStack(spacing: 0) {
            Seg {
                Circle()
                    .fill(health.tint)
                    .frame(width: 6, height: 6)
                Text(health == .receiving ? model.serialStatus.label : health.label)
            }
            .help(deviceHelp)
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
        .font(.system(size: 11, design: .monospaced))
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
