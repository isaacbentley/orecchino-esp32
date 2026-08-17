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
            self.tryOpen()
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
    /// the shared queue (drain, reconnect timer) is never blocked.
    func send(_ line: String) {
        queue.async {
            guard self.fd >= 0 else { return }
            self.txBuf.append(contentsOf: (line + "\n").utf8)
            self.flushTx()
        }
    }

    // MARK: - queue-confined

    private var txBuf = Data()
    private var txRetryPending = false

    private func flushTx() {
        guard fd >= 0 else {
            txBuf.removeAll()
            return
        }
        while !txBuf.isEmpty {
            let n = txBuf.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                txBuf.removeFirst(n)
            } else if n < 0 && errno == EINTR {
                continue
            } else if n < 0 && errno == EAGAIN {
                if !txRetryPending {
                    txRetryPending = true
                    queue.asyncAfter(deadline: .now() + .milliseconds(2)) { [weak self] in
                        guard let self else { return }
                        self.txRetryPending = false
                        self.flushTx()
                    }
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
    private var sawJson = false

    private func startReconnectTimer() {
        reconnect?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            if self.fd < 0 {
                self.tryOpen()
            } else if self.preferredPath == nil, !self.sawJson,
                      Date().timeIntervalSince(self.openedAt) > 6 {
                // Connected but silent — multi-port devices (e.g. the
                // SenseCAP's RP2040 CDC vs its CH340) mean the first port
                // isn't always the right one. Rotate until JSON appears.
                self.candidateIdx += 1
                self.closePort()
                self.onStatus?(.searching)
                self.tryOpen()
            }
        }
        t.resume()
        reconnect = t
    }

    /// ORECCHINO_DEBUG=1 traces port selection to /tmp/orecchino-serial.log
    private let debug = ProcessInfo.processInfo.environment["ORECCHINO_DEBUG"] != nil
    private func dlog(_ s: String) {
        guard debug else { return }
        let line = "\(Date()) \(s)\n"
        if let d = line.data(using: .utf8),
           let h = FileHandle(forWritingAtPath: "/tmp/orecchino-serial.log") {
            h.seekToEndOfFile()
            h.write(d)
            try? h.close()
        } else {
            FileManager.default.createFile(atPath: "/tmp/orecchino-serial.log",
                                           contents: line.data(using: .utf8))
        }
    }

    private func tryOpen() {
        let cands = Self.candidatePorts()
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

        fd = f
        currentPath = path
        buffer.removeAll()
        openedAt = Date()
        sawJson = false

        let src = DispatchSource.makeReadSource(fileDescriptor: f, queue: queue)
        src.setEventHandler { [weak self] in self?.drain() }
        src.setCancelHandler { [f] in Darwin.close(f) }
        src.resume()
        source = src
        onStatus?(.connected(path))
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
