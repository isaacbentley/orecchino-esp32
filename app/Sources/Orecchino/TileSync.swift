import Foundation
import Observation

/// Keeps the receiver's offline map tiles current: downloads the configured
/// coverage from CARTO into Application Support, then pushes missing or
/// changed tiles to the device over the serial link (base64 chunks, per-chunk
/// acks, CRC32 per file). Incremental: unchanged tiles are skipped.
@MainActor
@Observable
final class TileSync {
    enum Phase: Equatable {
        case idle
        case fetching(Int, Int)     // downloaded, total expected
        case listing
        case syncing(Int, Int)      // files sent, files to send
        case done(Int)              // files sent
        case failed(String)

        var label: String? {
            switch self {
            case .idle: return nil
            case .fetching(let a, let b): return "tiles \(a)/\(b) dl"
            case .listing: return "tiles: device list"
            case .syncing(let a, let b): return "tiles \(a)/\(b) send"
            case .done(let n): return n == 0 ? "tiles current" : "tiles synced \(n)"
            case .failed(let e): return "tiles: \(e)"
            }
        }
    }

    var phase: Phase = .idle

    // Coverage recipe — keep in sync with tools/fetch_tiles.py
    static let bbox = (s: 37.690, w: -122.527, n: 37.836, e: -122.343)
    static let zooms = 11...15
    private static let chunkBytes = 768
    private static let tileURL = "https://basemaps.cartocdn.com/dark_all/%d/%d/%d.png"

    private enum State { case idle, awaitList, deleting, awaitAck, awaitOk }
    private var state: State = .idle
    private var deviceFiles: [String: Int] = [:]
    private var deleteQueue: [String] = []
    private var sendQueue: [(rel: String, url: URL)] = []
    private var sentCount = 0
    private var totalToSend = 0
    private var fileData = Data()
    private var fileOffset = 0
    private var currentRel = ""
    private var seq = 0
    private var running = false
    private var timeout: Task<Void, Never>?

    private var localRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("Orecchino/tiles", isDirectory: true)
    }

    static func deg2tile(lat: Double, lon: Double, z: Int) -> (x: Int, y: Int) {
        let n = Double(1 << z)
        let x = Int((lon + 180) / 360 * n)
        let rad = lat * .pi / 180
        let y = Int((1 - log(tan(rad) + 1 / cos(rad)) / .pi) / 2 * n)
        return (x, y)
    }

    private func expectedTiles() -> [(z: Int, x: Int, y: Int)] {
        var out: [(Int, Int, Int)] = []
        for z in Self.zooms {
            let a = Self.deg2tile(lat: Self.bbox.n, lon: Self.bbox.w, z: z)
            let b = Self.deg2tile(lat: Self.bbox.s, lon: Self.bbox.e, z: z)
            for x in min(a.x, b.x)...max(a.x, b.x) {
                for y in min(a.y, b.y)...max(a.y, b.y) {
                    out.append((z, x, y))
                }
            }
        }
        return out
    }

    func start() {
        guard !running else { return }
        running = true
        Task { await run() }
    }

    private func run() async {
        defer { running = false }
        let tiles = expectedTiles()

        // 1. Fill the local cache from CARTO (skip anything present).
        var have = 0
        var session = URLSession.shared
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpAdditionalHeaders =
            ["User-Agent": "orecchino-esp32 tile sync (offline device map)"]
        session = URLSession(configuration: cfg)
        for (i, t) in tiles.enumerated() {
            let url = localRoot.appendingPathComponent("\(t.z)/\(t.x)/\(t.y).png")
            if FileManager.default.fileExists(atPath: url.path) {
                have += 1
                continue
            }
            phase = .fetching(i, tiles.count)
            guard let remote = URL(string: String(format: Self.tileURL, t.z, t.x, t.y))
            else { continue }
            do {
                let (data, resp) = try await session.data(from: remote)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { continue }
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try data.write(to: url)
                have += 1
                try? await Task.sleep(nanoseconds: 250_000_000)  // be polite
            } catch {
                // Offline is fine — sync whatever the cache holds.
                break
            }
        }
        guard have > 0 else {
            phase = .failed("no local tiles")
            return
        }

        // 2. Ask the device what it has.
        guard AppModel.shared.serialStatus.isConnected else {
            phase = .failed("no device")
            return
        }
        deviceFiles = [:]
        state = .awaitList
        phase = .listing
        send(#"{"cmd":"fs_ls"}"#)
        armTimeout(seconds: 30)
    }

    private func send(_ line: String) {
        AppModel.shared.serial.send(line)
    }

    private func armTimeout(seconds: Double = 8) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            guard let self, !Task.isCancelled else { return }
            self.state = .idle
            self.phase = .failed("timeout")
            self.running = false
        }
    }

    /// Routed from AppModel.ingest for fs_*/ack message types.
    func handle(_ msg: RidMessage) {
        timeout?.cancel()
        switch msg.type {
        case "fs_f":
            if let p = msg.p, let s = msg.s { deviceFiles[p] = s }
            armTimeout(seconds: 15)
        case "fs_ls_done":
            buildQueueAndGo()
        case "ack":
            sendNextChunk()
        case "fs_ok":
            if state == .deleting {
                nextDelete()
            } else {
                sentCount += 1
                phase = .syncing(sentCount, totalToSend)
                nextFile()
            }
        case "fs_err":
            state = .idle
            phase = .failed(msg.msg ?? "device error")
            running = false
        default:
            break
        }
    }

    private func buildQueueAndGo() {
        sendQueue = []
        let fm = FileManager.default
        var expected = Set<String>()
        for t in expectedTiles() {
            let rel = "/tiles/\(t.z)/\(t.x)/\(t.y).png"
            expected.insert(rel)
            let url = localRoot.appendingPathComponent("\(t.z)/\(t.x)/\(t.y).png")
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int else { continue }
            if deviceFiles[rel] != size {
                sendQueue.append((rel, url))
            }
        }
        // Prune orphans first: coverage changes free device space before the
        // new tiles start arriving.
        deleteQueue = deviceFiles.keys.filter { !expected.contains($0) }.sorted()
        sentCount = 0
        totalToSend = sendQueue.count
        nextDelete()
    }

    private func nextDelete() {
        guard let rel = deleteQueue.first else {
            phase = .syncing(0, totalToSend)
            nextFile()
            return
        }
        deleteQueue.removeFirst()
        state = .deleting
        send(#"{"cmd":"fs_rm","p":"\#(rel)"}"#)
        armTimeout()
    }

    private func nextFile() {
        guard let item = sendQueue.first else {
            state = .idle
            phase = .done(sentCount)
            running = false
            return
        }
        sendQueue.removeFirst()
        guard let data = try? Data(contentsOf: item.url) else {
            nextFile()
            return
        }
        fileData = data
        fileOffset = 0
        seq = 0
        currentRel = item.rel
        state = .awaitAck
        send(#"{"cmd":"fs_begin","p":"\#(item.rel)","size":\#(data.count)}"#)
        armTimeout()
    }

    private func sendNextChunk() {
        guard state == .awaitAck || state == .awaitOk else { return }
        if fileOffset >= fileData.count {
            state = .awaitOk
            send(#"{"cmd":"fs_end","crc":\#(Self.crc32(fileData))}"#)
            armTimeout()
            return
        }
        let end = min(fileOffset + Self.chunkBytes, fileData.count)
        let b64 = fileData[fileOffset..<end].base64EncodedString()
        fileOffset = end
        seq += 1
        send(#"{"cmd":"fs_data","q":\#(seq),"b64":"\#(b64)"}"#)
        armTimeout()
    }

    static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFFFFFF
        for b in data { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFFFFFF
    }
}
