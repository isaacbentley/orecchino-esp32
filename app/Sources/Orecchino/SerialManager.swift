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

    // MARK: - queue-confined

    private func startReconnectTimer() {
        reconnect?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in
            guard let self, self.fd < 0 else { return }
            self.tryOpen()
        }
        t.resume()
        reconnect = t
    }

    private func tryOpen() {
        let path = preferredPath ?? Self.candidatePorts().first
        guard let path else {
            onStatus?(.searching)
            return
        }
        let f = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard f >= 0 else {
            onStatus?(.searching)
            return
        }

        var tio = termios()
        if tcgetattr(f, &tio) == 0 {
            cfmakeraw(&tio)
            cfsetspeed(&tio, speed_t(B115200))
            tio.c_cflag |= tcflag_t(CLOCAL | CREAD)
            tcsetattr(f, TCSANOW, &tio)
        }

        fd = f
        currentPath = path
        buffer.removeAll()

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
                if !trimmed.isEmpty { onLine?(trimmed) }
            }
        }
    }
}
