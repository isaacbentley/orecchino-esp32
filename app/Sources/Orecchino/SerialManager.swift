import Foundation
import Darwin

enum SerialStatus: Equatable {
    case searching
    case connected(String)
    case failed(String)

    var label: String {
        switch self {
        case .searching: return "searching for device…"
        case .connected(let p): return (p as NSString).lastPathComponent
        case .failed(let e): return "error: \(e)"
        }
    }
    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// Reads newline-delimited JSON from a USB CDC serial port on a background
/// queue. Auto-connects to the first ESP32-looking port and reconnects on
/// unplug. Values never cross threads raw: callbacks are invoked on `queue`
/// and the owner hops to the main actor.
final class SerialManager: @unchecked Sendable {
    private let queue = DispatchQueue(label: "orecchino.serial")
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var reconnect: DispatchSourceTimer?
    private var buffer = Data()
    private var currentPath: String?

    /// nil = auto-pick the first candidate port
    private var preferredPath: String?

    var onLine: (@Sendable (String) -> Void)?
    var onStatus: (@Sendable (SerialStatus) -> Void)?
    /// The candidate ports, whenever the list changes (the reconnect timer
    /// lists /dev every 2 s; views read the copy rather than /dev).
    var onPorts: (@Sendable ([String]) -> Void)?

    static func candidatePorts() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        let prefixes = ["cu.usbmodem", "cu.usbserial", "cu.SLAB_USBtoUART", "cu.wchusbserial"]
        return names
            .filter { n in prefixes.contains(where: { n.hasPrefix($0) }) }
            .sorted()
            .map { "/dev/" + $0 }
    }

    func start(preferred: String?) {
        queue.async {
            self.preferredPath = preferred
            self.closePort()
            self.tryOpen(self.listPorts())
            self.startReconnectTimer()
        }
    }

    func stop() {
        queue.async {
            self.reconnect?.cancel()
            self.reconnect = nil
            self.closePort()
            self.onStatus?(.searching)
        }
    }

    /// Write one line to the device (used by the tile sync protocol).
    /// Buffered: bytes the port can't take yet are retried via asyncAfter so
    /// the shared queue (drain, reconnect timer) is never blocked. The
    /// buffer is capped at `txCap`: a receiver that stops draining USB (a
    /// Wi-Fi fetch, an e-paper refresh) loses the oldest whole lines, and
    /// the retry backs off from 2 ms to 50 ms while it stays full.
    func send(_ line: String) {
        queue.async {
            guard self.fd >= 0 else { return }
            self.txBuf.append(contentsOf: (line + "\n").utf8)
            self.txBuf = Self.capped(self.txBuf, at: Self.txCap)
            self.flushTx()
        }
    }

    static let txCap = 64 * 1024

    /// `buf` cut to at most `cap` bytes by dropping its oldest whole lines
    /// (the last line is kept whole even when it alone is over the cap, so
    /// a partial line is never sent).
    nonisolated static func capped(_ buf: Data, at cap: Int) -> Data {
        var out = buf
        while out.count > cap, let nl = out.firstIndex(of: 0x0A), nl < out.index(before: out.endIndex) {
            out.removeSubrange(out.startIndex...nl)
        }
        return out
    }

    // MARK: - queue-confined

    private var txBuf = Data()
    private var txRetryPending = false
    private var txRetryMs = 2

    private func flushTx() {
        guard fd >= 0 else {
            txBuf.removeAll()
            return
        }
        while !txBuf.isEmpty {
            let n = txBuf.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                txBuf.removeFirst(n)
                txRetryMs = 2
            } else if n < 0 && errno == EINTR {
                continue
            } else if n < 0 && errno == EAGAIN {
                if !txRetryPending {
                    txRetryPending = true
                    queue.asyncAfter(deadline: .now() + .milliseconds(txRetryMs)) { [weak self] in
                        guard let self else { return }
                        self.txRetryPending = false
                        self.flushTx()
                    }
                    txRetryMs = min(50, txRetryMs * 2)
                }
                return
            } else {
                // Hard error — the read path notices the unplug and reconnects.
                txBuf.removeAll()
                return
            }
        }
    }

    private var candidateIdx = 0
    private var openedAt = Date.distantPast
    private var lastByteAt = Date.distantPast
    private var sawJson = false
    private var lastPorts: [String]?

    /// An open port that has said nothing for this long is closed and
    /// opened again: a receiver that reset, or was pulled without the
    /// driver delivering EOF, leaves the descriptor open but dead.
    static let silentReopenAfter: TimeInterval = 15

    /// /dev listed once per tick, and published when it changes.
    private func listPorts() -> [String] {
        let ports = Self.candidatePorts()
        if ports != lastPorts {
            lastPorts = ports
            onPorts?(ports)
        }
        return ports
    }

    private func startReconnectTimer() {
        reconnect?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let ports = self.listPorts()
            if self.fd < 0 {
                self.tryOpen(ports)
            } else if self.preferredPath == nil, !self.sawJson,
                      Date().timeIntervalSince(self.openedAt) > 6 {
                // Connected but silent — multi-port devices (e.g. the
                // SenseCAP's RP2040 CDC vs its CH340) mean the first port
                // isn't always the right one. Rotate until JSON appears.
                self.candidateIdx += 1
                self.closePort()
                self.onStatus?(.searching)
                self.tryOpen(ports)
            } else if self.sawJson,
                      Date().timeIntervalSince(self.lastByteAt) > Self.silentReopenAfter {
                // It spoke, then went quiet with the port still open: open
                // the same port again rather than wait for an EOF that may
                // never come.
                self.dlog("silent for \(Int(Self.silentReopenAfter)) s, reopening")
                self.closePort()
                self.onStatus?(.searching)
                // The descriptor closes in the source's cancel handler,
                // queued behind this block: open the same port after it.
                self.queue.asyncAfter(deadline: .now() + .milliseconds(100)) { self.tryOpen(ports) }
            }
        }
        t.resume()
        reconnect = t
    }

    /// ORECCHINO_DEBUG=1 traces port selection to
    /// ~/Library/Logs/Orecchino/serial.log: a per-user place, opened without
    /// following a symlink and readable by this user only (0600).
    private let debug = ProcessInfo.processInfo.environment["ORECCHINO_DEBUG"] != nil
    static var debugLogPath: String {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/Orecchino", isDirectory: true)
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/Orecchino")
        return logs.appendingPathComponent("serial.log").path
    }
    private func dlog(_ s: String) {
        guard debug else { return }
        let path = Self.debugLogPath
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let f = Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard f >= 0 else { return }
        defer { Darwin.close(f) }
        let bytes = Array("\(Date()) \(s)\n".utf8)
        _ = bytes.withUnsafeBytes { Darwin.write(f, $0.baseAddress, $0.count) }
    }

    private func tryOpen(_ cands: [String]) {
        let path = preferredPath ?? (cands.isEmpty ? nil : cands[candidateIdx % cands.count])
        guard let path else {
            dlog("no candidates")
            onStatus?(.searching)
            return
        }
        dlog("trying \(path) of \(cands.count) candidates idx=\(candidateIdx)")
        let f = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard f >= 0 else {
            dlog("open failed errno=\(errno)")
            // A port another program holds (EBUSY) must not stop the
            // search: the next tick tries the next candidate.
            if preferredPath == nil { candidateIdx += 1 }
            onStatus?(.searching)
            return
        }
        dlog("opened \(path) fd=\(f)")

        var tio = termios()
        if tcgetattr(f, &tio) == 0 {
            cfmakeraw(&tio)
            // 460800 for the SenseCAP's CH340 UART; USB-CDC devices (XIAO)
            // ignore the baud entirely.
            cfsetspeed(&tio, 460800)
            tio.c_cflag |= tcflag_t(CLOCAL | CREAD)
            tcsetattr(f, TCSANOW, &tio)
        }
        attach(fd: f, path: path)
    }

    /// Read lines from an open descriptor as if it were the receiver's
    /// port; the tests feed one end of a pipe() through here.
    func attach(fd f: Int32, path: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        // drain() reads until EAGAIN: a blocking descriptor would hold the queue.
        _ = fcntl(f, F_SETFL, fcntl(f, F_GETFL) | O_NONBLOCK)
        fd = f
        currentPath = path
        buffer.removeAll()
        openedAt = Date()
        lastByteAt = openedAt
        sawJson = false

        let src = DispatchSource.makeReadSource(fileDescriptor: f, queue: queue)
        src.setEventHandler { [weak self] in self?.drain() }
        src.setCancelHandler { [f] in Darwin.close(f) }
        src.resume()
        source = src
        onStatus?(.connected(path))
    }

    /// `attach` from off the queue (tests).
    func attachAsync(fd f: Int32, path: String) {
        queue.async { self.attach(fd: f, path: path) }
    }

    private func closePort() {
        source?.cancel()   // cancel handler closes the fd
        source = nil
        fd = -1
        currentPath = nil
        buffer.removeAll()
        txBuf.removeAll()
    }

    private func drain() {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                lastByteAt = Date()
                buffer.append(contentsOf: chunk[0..<n])
                if buffer.count > 1 << 20 { buffer.removeAll() }  // runaway garbage
                continue
            }
            if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
                // Device unplugged or hard error: close and let the timer retry.
                closePort()
                onStatus?(.searching)
                return
            }
            break  // EAGAIN — drained
        }
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let s = String(data: Data(lineData), encoding: .utf8) {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    if trimmed.hasPrefix("{") { sawJson = true }
                    onLine?(trimmed)
                }
            }
        }
    }
}
