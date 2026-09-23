import SwiftUI
import AppKit
import Observation

/// One record from the receiver's match log: a contact it has lost (or,
/// with `active`, one it still holds), summarised on the device.
struct DeviceLogEntry: Identifiable, Equatable {
    let id: String
    let index: Int?          // nil for a contact still live on the device
    let active: Bool
    let uasId: String
    let mac: String
    let sources: Int         // bit0 Wi-Fi beacon, bit1 NAN, bit2 BLE
    let formats: Int         // bit0 ASTM F3411, bit1 GB 46750
    let uaType: Int
    let first: Date?         // nil when the receiver's clock was never set
    let last: Date?
    let duration: TimeInterval
    let lat: Double?
    let lon: Double?
    let maxHeight: Int?
    let peakRssi: Int
    let authState: String
    let inTFR: Bool
    let emergency: Bool
    let messages: Int

    var sourceText: String {
        var s: [String] = []
        if sources & 1 != 0 { s.append("Wi-Fi") }
        if sources & 2 != 0 { s.append("NAN") }
        if sources & 4 != 0 { s.append("BLE") }
        return s.isEmpty ? "—" : s.joined(separator: " + ")
    }
    var displayName: String { uasId.isEmpty ? mac : uasId }

    init?(_ m: RidMessage) {
        guard m.type == "log", let mac = m.mac else { return nil }
        let i = m.i ?? -1
        index = i >= 0 ? i : nil
        active = m.active ?? false
        uasId = m.uas ?? ""
        self.mac = mac
        id = active ? "live:\(mac)" : "rec:\(i)"
        sources = m.srcs ?? 0
        formats = m.fmts ?? 0
        uaType = m.ua_type ?? 0
        first = (m.first ?? 0) > 0 ? Date(timeIntervalSince1970: TimeInterval(m.first!)) : nil
        last = (m.last ?? 0) > 0 ? Date(timeIntervalSince1970: TimeInterval(m.last!)) : nil
        duration = TimeInterval(m.dur ?? 0)
        lat = m.lat
        lon = m.lon
        maxHeight = m.max_h
        peakRssi = m.peak_rssi ?? -127
        authState = m.auth_state ?? "none"
        inTFR = m.tfr ?? false
        emergency = m.emerg ?? false
        messages = m.msgs ?? 0
    }
}

/// Reads and clears the receiver's match log over the serial link.
@MainActor
@Observable
final class DeviceLog {
    enum Phase: Equatable {
        case idle, fetching, done, failed(String)
    }

    var entries: [DeviceLogEntry] = []
    var phase: Phase = .idle
    /// From log_done: whether the receiver's clock was set, so the times
    /// in the records mean anything.
    var clockSet = true
    /// Records the receiver has ever written, including ones since overwritten.
    var totalEver = 0
    var isPresented = false

    @ObservationIgnored private var pending: [DeviceLogEntry] = []
    @ObservationIgnored private var timeout: Task<Void, Never>?

    func fetch() {
        guard AppModel.shared.serialStatus.isConnected else {
            phase = .failed("no receiver connected")
            return
        }
        pending = []
        phase = .fetching
        AppModel.shared.serial.send(#"{"cmd":"log_get"}"#)
        armTimeout()
    }

    /// The link went away mid-read: say so, rather than let the timeout
    /// blame the firmware.
    func cancel() {
        guard phase == .fetching else { return }
        timeout?.cancel()
        pending = []
        phase = .failed("receiver disconnected while reading")
    }

    func clear() {
        guard AppModel.shared.serialStatus.isConnected else { return }
        AppModel.shared.serial.send(#"{"cmd":"log_clear"}"#)
    }

    /// Routed from AppModel.ingest for log / log_done / log_cleared.
    func handle(_ m: RidMessage) {
        switch m.type {
        case "log":
            guard phase == .fetching, let e = DeviceLogEntry(m) else { return }
            pending.append(e)
            armTimeout()
        case "log_done":
            guard phase == .fetching else { return }
            timeout?.cancel()
            // Live contacts first, then ended ones newest first.
            entries = pending.filter(\.active)
                + pending.filter { !$0.active }.sorted { ($0.index ?? 0) > ($1.index ?? 0) }
            clockSet = m.clock ?? true
            totalEver = m.total ?? entries.count
            phase = .done
        case "log_cleared":
            entries.removeAll { !$0.active }
            totalEver = 0
        default:
            break
        }
    }

    private func armTimeout() {
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, !Task.isCancelled, self.phase == .fetching else { return }
            self.phase = .failed("no answer — this firmware may not keep a log")
        }
    }

    nonisolated static func csv(_ rows: [DeviceLogEntry]) -> String {
        let iso = ISO8601DateFormatter()
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var out = "status,uas_id,mac,sources,first_utc,last_utc,duration_s,lat,lon,max_height_m,peak_rssi,auth,tfr,emergency,messages\n"
        for e in rows {
            let cols: [String] = [
                e.active ? "live" : "ended", q(e.uasId), e.mac, q(e.sourceText),
                e.first.map { iso.string(from: $0) } ?? "", e.last.map { iso.string(from: $0) } ?? "",
                String(Int(e.duration)),
                e.lat.map { String(format: "%.5f", $0) } ?? "", e.lon.map { String(format: "%.5f", $0) } ?? "",
                e.maxHeight.map(String.init) ?? "", String(e.peakRssi), e.authState,
                e.inTFR ? "yes" : "no", e.emergency ? "yes" : "no", String(e.messages),
            ]
            out += cols.joined(separator: ",") + "\n"
        }
        return out
    }

    func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "orecchino-match-log.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Self.csv(entries).write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - View

struct DeviceLogView: View {
    @Environment(AppModel.self) private var model
    private var log: DeviceLog { model.deviceLog }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Receiver Match Log").font(.title2.weight(.semibold))
                    Text(summary).font(.callout).foregroundStyle(Theme.muted)
                }
                Spacer()
                Button {
                    log.fetch()
                } label: {
                    Label(log.phase == .fetching ? "Reading…" : "Read from Receiver",
                          systemImage: "arrow.down.circle")
                }
                .disabled(log.phase == .fetching || !model.serialStatus.isConnected)
                Button("Export CSV…") { log.exportCSV() }
                    .disabled(log.entries.isEmpty)
                Button("Clear on Receiver", role: .destructive) { log.clear() }
                    .disabled(!model.serialStatus.isConnected || log.entries.allSatisfy(\.active))
            }
            if !log.clockSet {
                Label("The receiver's clock was not set when these were recorded, so times are missing. Connect the app before flying to set it.",
                      systemImage: "clock.badge.exclamationmark")
                    .font(.callout).foregroundStyle(Theme.warn)
            }
            if case .failed(let why) = log.phase {
                Label(why, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warn)
            }
            if log.entries.isEmpty {
                ContentUnavailableView(
                    log.phase == .done ? "No contacts logged" : "Nothing read yet",
                    systemImage: "list.bullet.rectangle",
                    description: Text(log.phase == .done
                        ? "The receiver has not lost track of any drone since the log was last cleared."
                        : "Read the receiver's log to see every drone it has heard, even while no app was connected."))
            } else {
                Table(log.entries) {
                    TableColumn("") { e in
                        Image(systemName: e.active ? "dot.radiowaves.left.and.right" : "clock.arrow.circlepath")
                            .foregroundStyle(e.active ? Theme.ok : Theme.muted)
                            .help(e.active ? "Still in the receiver's table" : "Ended")
                            .accessibilityLabel(e.active ? "Live" : "Ended")
                    }.width(22)
                    TableColumn("Drone") { e in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.displayName).font(.body.monospaced())
                            if !e.uasId.isEmpty {
                                Text(e.mac).font(.caption.monospaced()).foregroundStyle(Theme.muted)
                            }
                        }
                    }.width(min: 170, ideal: 210)
                    TableColumn("Heard") { e in
                        Text(e.last.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
                            .foregroundStyle(e.last == nil ? Theme.unknown : .primary)
                    }.width(min: 120, ideal: 150)
                    TableColumn("For") { e in Text(fmtDuration(e.duration)) }.width(60)
                    TableColumn("Via") { e in Text(e.sourceText) }.width(min: 70, ideal: 100)
                    TableColumn("Peak") { e in Text("\(e.peakRssi) dBm").monospacedDigit() }.width(70)
                    TableColumn("Max height") { e in
                        Text(e.maxHeight.map { "\($0) m" } ?? "—").monospacedDigit()
                    }.width(80)
                    TableColumn("Flags") { e in
                        HStack(spacing: 4) {
                            if e.emergency { Tag(text: "EMERGENCY", tint: Theme.danger) }
                            if e.inTFR { Tag(text: "TFR", tint: Theme.warn) }
                            if let a = RidNames.authLabel(e.authState) {
                                Tag(text: a, tint: e.authState == "invalid" ? Theme.danger
                                                  : e.authState == "id_valid" ? Theme.ok : Theme.muted)
                            }
                        }
                    }.width(min: 120, ideal: 200)
                }
            }
            HStack {
                Spacer()
                Button("Done") { log.isPresented = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 860, minHeight: 440)
        .onAppear { if log.phase == .idle && model.serialStatus.isConnected { log.fetch() } }
    }

    private var summary: String {
        let ended = log.entries.filter { !$0.active }.count
        let live = log.entries.count - ended
        switch log.phase {
        case .idle: return "Every contact the receiver has lost, kept across power cycles."
        case .fetching: return "Reading…"
        default:
            var s = "\(ended) ended, \(live) live"
            if log.totalEver > ended { s += " · \(log.totalEver - ended) older records overwritten" }
            return s
        }
    }
}

private struct Tag: View {
    let text: String
    let tint: Color
    var body: some View {
        Text(text).font(.caption2.weight(.semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(tint)
    }
}

func fmtDuration(_ s: TimeInterval) -> String {
    let t = Int(s)
    if t < 60 { return "\(t) s" }
    if t < 3600 { return "\(t / 60) min" }
    return "\(t / 3600) h \(t % 3600 / 60) min"
}
