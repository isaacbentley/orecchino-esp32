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
    /// Inside a pushed TFR at some point; `inTFRNow` at its last position
    /// (a live contact: now); `tfrId` the one it was last inside.
    let inTFR: Bool
    let inTFRNow: Bool
    let tfrId: String?
    let emergency: Bool
    /// The last System message's UA classification, raw (class type 1 = EU).
    let classType: Int?
    let catEu: Int?
    let classEu: Int?
    let messages: Int

    var classification: String? {
        RidNames.classification(type: classType, category: catEu, cls: classEu)
    }
    /// "IN TFR 6/3221" while inside, "TFR 6/3221" once out; nil when never.
    var tfrText: String? {
        guard inTFR else { return nil }
        let head = inTFRNow ? "IN TFR" : "TFR"
        return tfrId.map { "\(head) \($0)" } ?? head
    }

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
        let i = m.seq ?? m.i ?? -1
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
        inTFRNow = m.in_tfr ?? false
        tfrId = m.tfr_id.flatMap { $0.isEmpty ? nil : String($0.prefix(16)) }
        emergency = m.emerg ?? false
        classType = m.class_type
        catEu = m.class_type == 1 ? m.cat_eu : nil
        classEu = m.class_type == 1 ? m.class_eu : nil
        messages = m.msgs ?? 0
    }
}

/// Reads and clears the receiver's match log over the serial link.
///
/// Incremental sync (rx_core.h emit_log): an ended contact's record has a
/// sequence number `seq` that never changes; a live contact comes with
/// "active":true and no number, every time, until it ends. log_done's `next`
/// is stored and sent back as {"cmd":"log_get","since":next}, so only new
/// records cross the link; live contacts are replaced on every read. A
/// cursor above the receiver's `total` means its log was cleared (or this is
/// another receiver): the store is dropped and the read restarts from
/// `oldest`. A cursor below `oldest` means records rotated out unseen.
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
    /// Ended records that rotated out of the receiver's ring before this app
    /// read them (oldest minus the cursor, when positive).
    var missed = 0
    var isPresented = false
    /// The "Clear on Receiver" confirmation is up.
    var confirmClear = false
    /// The receiver cleared its log (this app's clear, another host's, or
    /// the board's CLEAR HISTORY) since the last read: what is shown is
    /// this Mac's copy, kept until the next read replaces it.
    var clearedSinceRead = false

    /// The `since` for the next read; nil reads everything.
    @ObservationIgnored private(set) var cursor: Int?
    /// The receiver's `log_id` the cursor belongs to (bumped by a clear);
    /// nil until a log_done or log_cleared carried one.
    @ObservationIgnored private(set) var logId: Int?
    @ObservationIgnored private var sentSince: Int?
    @ObservationIgnored private var ended: [Int: DeviceLogEntry] = [:]
    @ObservationIgnored private var restarted = false
    @ObservationIgnored private var pending: [DeviceLogEntry] = []
    @ObservationIgnored private var timeout: Task<Void, Never>?
    /// Where commands go; the app's serial link unless a test replaces it.
    @ObservationIgnored var send: (String) -> Void = { AppModel.shared.serial.send($0) }
    @ObservationIgnored var isConnected: () -> Bool = { AppModel.shared.serialStatus.isConnected }

    nonisolated static func getCommand(since: Int?) -> String {
        since.map { #"{"cmd":"log_get","since":\#($0)}"# } ?? #"{"cmd":"log_get"}"#
    }

    func fetch() {
        guard isConnected() else {
            phase = .failed("no receiver connected")
            return
        }
        restarted = false
        request(since: cursor)
    }

    private func request(since: Int?) {
        pending = []
        phase = .fetching
        sentSince = since
        send(Self.getCommand(since: since))
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

    /// Another port (maybe another receiver): the cursor means nothing there.
    /// What is shown stays until the next read replaces it.
    func forgetCursor() {
        cursor = nil
        logId = nil
    }

    func clear() {
        guard isConnected() else { return }
        send(#"{"cmd":"log_clear"}"#)
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
            if m.err == "dropped" {
                // The receiver lost lines of this dump (a BLE/USB drop) and
                // `next` is the `since` asked for: nothing is stored and
                // the cursor stays, so the next read asks for it all again.
                pending = []
                phase = .failed("the receiver dropped part of the log — read again")
                return
            }
            let total = m.total ?? m.next
            // Another log: the receiver says so (log_id), or the cursor is
            // past its total (cleared, or a different receiver).
            let otherLog = m.log_id.map { id in logId.map { $0 != id } ?? false } ?? false
            let pastEnd = sentSince.map { since in total.map { since > $0 } ?? false } ?? false
            if let id = m.log_id { logId = id }
            if sentSince != nil, otherLog || pastEnd, !restarted {
                // Start again from oldest; what was held is of the old log.
                restarted = true
                ended = [:]
                cursor = nil
                missed = m.oldest ?? 0
                request(since: m.oldest ?? 0)
                return
            }
            if let since = sentSince {
                missed += max(0, (m.oldest ?? since) - since)
            } else {
                ended = [:]                        // a full read replaces the store
                missed = m.oldest ?? 0
            }
            for e in pending where !e.active { if let i = e.index { ended[i] = e } }
            cursor = m.next ?? m.total
            // Live contacts first, then ended ones newest first.
            entries = pending.filter(\.active)
                + ended.values.sorted { ($0.index ?? 0) > ($1.index ?? 0) }
            clockSet = m.clock ?? true
            totalEver = total ?? entries.count
            clearedSinceRead = false
            phase = .done
        case "log_cleared":
            // The receiver's copy is gone; this Mac's stays on show (and
            // exportable) until the next read, which starts from 0.
            ended = [:]
            cursor = 0
            if let id = m.log_id { logId = id }
            missed = 0
            totalEver = 0
            clearedSinceRead = !entries.isEmpty
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
        // Text from the receiver is quoted, and a leading = + - @ tab or CR
        // gets a ' so a spreadsheet shows it rather than runs it as a formula.
        func q(_ s: String) -> String {
            var t = s
            if let c = t.first, "=+-@\t\r".contains(c) { t = "'" + t }
            return "\"" + t.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var out = "status,uas_id,mac,sources,first_utc,last_utc,duration_s,lat,lon,max_height_m,peak_rssi,auth,"
            + "tfr,in_tfr,tfr_id,class,emergency,messages\n"
        for e in rows {
            let cols: [String] = [
                e.active ? "live" : "ended", q(e.uasId), q(e.mac), q(e.sourceText),
                e.first.map { iso.string(from: $0) } ?? "", e.last.map { iso.string(from: $0) } ?? "",
                String(Int(e.duration)),
                e.lat.map { String(format: "%.5f", $0) } ?? "", e.lon.map { String(format: "%.5f", $0) } ?? "",
                e.maxHeight.map(String.init) ?? "", String(e.peakRssi), q(e.authState),
                e.inTFR ? "yes" : "no", e.inTFRNow ? "yes" : "no", e.tfrId.map(q) ?? "",
                e.classification.map(q) ?? "",
                e.emergency ? "yes" : "no", String(e.messages),
            ]
            out += cols.joined(separator: ",") + "\n"
        }
        return out
    }

    /// Saves what is shown; false when the panel was cancelled or the
    /// write failed, so a clear that was to follow an export does not.
    @discardableResult
    func exportCSV() -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "orecchino-match-log.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try Self.csv(entries).write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            phase = .failed("could not write the CSV: \(error.localizedDescription)")
            return false
        }
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
                Button("Clear on Receiver", role: .destructive) { log.confirmClear = true }
                    .disabled(!model.serialStatus.isConnected || log.entries.allSatisfy(\.active))
                    .confirmationDialog("Clear the match log on the receiver?",
                                        isPresented: Binding(get: { log.confirmClear },
                                                             set: { log.confirmClear = $0 }),
                                        titleVisibility: .visible) {
                        Button("Export CSV, then Clear") {
                            if log.exportCSV() { log.clear() }
                        }
                        Button("Clear", role: .destructive) { log.clear() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Every ended record on the receiver is erased and cannot be recovered. "
                             + "What this Mac has read stays shown until the next read.")
                    }
            }
            if log.clearedSinceRead {
                Label("The receiver's log was cleared. These records are this Mac's copy, shown until the next read.",
                      systemImage: "info.circle")
                    .font(.callout).foregroundStyle(Theme.muted)
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
                            if let t = e.tfrText { Tag(text: t, tint: Theme.warn) }
                            if let a = RidNames.authLabel(e.authState) {
                                Tag(text: a, tint: e.authState == "invalid" ? Theme.danger
                                                  : e.authState == "id_valid" ? Theme.ok : Theme.muted)
                            }
                        }
                    }.width(min: 120, ideal: 200)
                    TableColumn("Class") { e in
                        Text(e.classification ?? "—")
                            .foregroundStyle(e.classification == nil ? Theme.unknown : .primary)
                    }.width(min: 90, ideal: 130)
                }
            }
            HStack {
                Spacer()
                Button("Done") { log.isPresented = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 960, minHeight: 440)
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
            if log.missed > 0 { s += " · \(log.missed) older records overwritten before they were read" }
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
