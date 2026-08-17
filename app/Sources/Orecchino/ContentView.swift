import SwiftUI
import MapKit
import CoreLocation

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
        } detail: {
            MapPane()
        }
        .navigationTitle("Orecchino")
        .toolbar {
            ToolbarItemGroup {
                ConnectionBadge()
                PortMenu()
                Toggle(isOn: $model.followAll) {
                    Label("Follow", systemImage: "scope")
                }
                .help("Keep the map fitted to all drones")
                Toggle(isOn: $model.demoMode) {
                    Label("Demo", systemImage: "sparkles")
                }
                .help("Inject two simulated drones")
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
                .fill(model.serialStatus.isConnected ? Color.green : Color.orange)
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
            if ports.isEmpty {
                Text("No serial ports found")
            }
        } label: {
            Label("Port", systemImage: "cable.connector")
        }
        .menuIndicator(.visible)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section("Drones — \(model.trackList.count)") {
                ForEach(model.trackList) { t in
                    DroneRow(track: t)
                        .tag(t.id)
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

struct DroneRow: View {
    @Environment(AppModel.self) private var model
    let track: DroneTrack

    private var isStale: Bool {
        Date().timeIntervalSince(track.lastSeen) > AppModel.staleAfter
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(track.color.opacity(0.2)).frame(width: 34, height: 34)
                Image(systemName: "airplane")
                    .font(.system(size: 15))
                    .foregroundStyle(track.color)
                    .rotationEffect(.degrees((track.heading ?? 0) - 90))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(.body, design: .monospaced).weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    ForEach(track.sources.sorted(), id: \.self) { s in
                        Text(s.uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(track.color.opacity(0.25), in: Capsule())
                    }
                    Text("\(track.rssi) dBm")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(RidNames.status(track.status))
                        .font(.caption2)
                        .foregroundStyle(track.status == 3 ? Color.red : Color.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let h = track.height {
                    Text("\(Int(h)) m").font(.caption.monospacedDigit())
                }
                Text(track.lastSeen, style: .relative)
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .opacity(isStale ? 0.45 : 1.0)
        .padding(.vertical, 2)
    }
}

// MARK: - Map

struct MapPane: View {
    @Environment(AppModel.self) private var model
    // Hand-rolled @State: the CLT SDK is missing the SwiftUIMacros plugin.
    // Storing the State dynamic property directly is equivalent.
    private let cameraState = State(initialValue: MapCameraPosition.automatic)
    private var camera: Binding<MapCameraPosition> { cameraState.projectedValue }

    var body: some View {
        Map(position: camera) {
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
                        DroneMarker(track: t, selected: model.selection == t.id)
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
            }
        }
        .overlay(alignment: .bottom) {
            StatusBar()
        }
        .onChange(of: model.selection) { _, sel in
            guard let sel, let c = model.tracks[sel]?.coordinate else { return }
            withAnimation(.easeInOut(duration: 0.6)) {
                camera.wrappedValue = .region(MKCoordinateRegion(
                    center: c, latitudinalMeters: 2000, longitudinalMeters: 2000))
            }
        }
        .onChange(of: model.followAll) { _, on in
            if on { withAnimation { camera.wrappedValue = .automatic } }
        }
        .onChange(of: camera.wrappedValue) { _, newValue in
            if newValue.positionedByUser, model.followAll {
                model.followAll = false
            }
        }
    }
}

struct DroneMarker: View {
    let track: DroneTrack
    let selected: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.55))
                .frame(width: 30, height: 30)
                .overlay(Circle().stroke(track.color, lineWidth: selected ? 2.5 : 1.2))
            Image(systemName: track.heading != nil ? "location.north.fill" : "circle.fill")
                .font(.system(size: track.heading != nil ? 14 : 8))
                .foregroundStyle(track.color)
                .rotationEffect(.degrees(track.heading ?? 0))
        }
        .overlay(alignment: .bottom) {
            Text(track.title)
                .font(.system(size: 10, design: .monospaced))
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(.black.opacity(0.65), in: Capsule())
                .foregroundStyle(.white)
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

// MARK: - Detail card

struct DroneDetailCard: View {
    let track: DroneTrack

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(track.color).frame(width: 8, height: 8)
                Text(track.title)
                    .font(.system(.headline, design: .monospaced))
                Spacer(minLength: 12)
                Text(RidNames.uaType(track.uaType))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                if let idt = track.idType {
                    DetailRow(name: "ID type", value: RidNames.idType(idt))
                }
                if let c = track.coordinate {
                    DetailRow(name: "Position",
                              value: String(format: "%.6f, %.6f", c.latitude, c.longitude))
                }
                DetailRow(name: "Alt (geo)", value: track.altGeo.map { "\(Int($0)) m" })
                DetailRow(name: "Height", value: track.height.map { "\(Int($0)) m AGL" })
                DetailRow(name: "Speed", value: track.speed.map {
                    String(format: "%.1f m/s", $0) })
                DetailRow(name: "Climb", value: track.vspeed.map {
                    String(format: "%+.1f m/s", $0) })
                DetailRow(name: "Heading", value: track.heading.map { "\(Int($0))°" })
                DetailRow(name: "Status", value: RidNames.status(track.status))
                DetailRow(name: "Operator", value: track.operatorId)
                DetailRow(name: "Op. dist", value: track.operatorDistance.map {
                    $0 > 1000 ? String(format: "%.1f km", $0 / 1000) : "\(Int($0)) m" })
                DetailRow(name: "Self ID", value: track.selfDesc)
                DetailRow(name: "RSSI", value: "\(track.rssi) dBm")
                DetailRow(name: "Source", value: track.sources.sorted()
                    .joined(separator: ", ").uppercased())
                DetailRow(name: "MAC", value: track.macs.sorted().joined(separator: " "))
                DetailRow(name: "Messages", value: "\(track.msgCount)")
            }
            .font(.caption)
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct DetailRow: View {
    let name: String
    let value: String?
    var body: some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(name).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                Text(value).font(.caption.monospacedDigit()).textSelection(.enabled)
            }
        }
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    private var heartbeatOK: Bool {
        guard let hb = model.stats.lastHeartbeat else { return false }
        return Date().timeIntervalSince(hb) < 6
    }

    var body: some View {
        HStack(spacing: 14) {
            if let fw = model.stats.firmware {
                Text(fw)
            }
            Text("wifi \(model.stats.wifiFrames.formatted())")
            Text("ble \(model.stats.bleAdvs.formatted())")
            Text("rid \(model.stats.ridCount.formatted())")
            if model.stats.dropped > 0 {
                Text("drop \(model.stats.dropped)").foregroundStyle(.orange)
            }
            Text("ch \(model.stats.channel)")
            Text(model.stats.bleOk ? (model.stats.bleExt ? "BT5" : "BT4") : "no BT")
                .foregroundStyle(model.stats.bleOk ? Color.secondary : Color.orange)
            if model.serialStatus.isConnected && !heartbeatOK {
                Text("no heartbeat").foregroundStyle(.orange)
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 8)
    }
}
