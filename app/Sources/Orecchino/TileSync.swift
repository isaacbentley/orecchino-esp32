import Foundation
import Observation

/// Keeps the receiver's offline map tiles current, planned the way the
/// board plans its own Wi-Fi fetch (TilePlan.swift = tile_plan.h): a circle
/// around this Mac (3 km by default, zooms 12-15), sized to the board's
/// storage. `plan()` asks the board for its storage (fs_stat) and its tiles
/// (fs_ls) and shows the plan ("Map: 3 km z12–15 · 0.8 MB of 11.9 MB");
/// `send()` then downloads what the plan needs from Esri's World Dark Gray
/// Canvas (JPEG, no key: CARTO now answers "API KEY REQUIRED" placeholders
/// without one) into Application Support and pushes the missing or changed
/// tiles as /tiles/z/x/y.jpg (base64 chunks, per-chunk acks, CRC32 per file).
/// At most 4 tiles a second, only the planned area, the app named in the
/// User-Agent; Esri's terms apply. Tiles outside the plan are evicted only when the
/// new ones need the room, highest zoom and farthest first; a tile inside
/// the plan never is, and free space is never taken under the 1 MB reserve.
/// A plan tile the board holds as a CARTO .png is replaced by its .jpg (the
/// .png removed once the .jpg has landed), never kept beside it.
@MainActor
@Observable
final class TileSync {
    enum Phase: Equatable {
        case idle
        case planning
        case planned(String)        // the plan's words, waiting for send()
        case fetching(Int, Int)     // downloaded, total expected
        case syncing(Int, Int)      // files sent, files to send
        case done(Int, Int)         // files sent, plan tiles still missing
        case failed(String)

        var label: String? {
            switch self {
            case .idle: return nil
            case .planning: return "map: asking the receiver"
            case .planned(let d): return d
            case .fetching(let a, let b): return "tiles \(a)/\(b) dl"
            case .syncing(let a, let b): return "tiles \(a)/\(b) send"
            case .done(let n, let left):
                if left > 0 { return "tiles synced \(n), \(left) did not fit" }
                return n == 0 ? "tiles current" : "tiles synced \(n)"
            case .failed(let e): return "tiles: \(e)"
            }
        }
    }

    var phase: Phase = .idle
    /// The last plan, with what the board said about its storage.
    private(set) var currentPlan: TilePlanner.Plan?
    private(set) var storageKnown = false

    /// Map radius in km (Settings), 1-30; 3 by default.
    nonisolated static let radiusKey = "tileRadiusKm"
    nonisolated static var radiusKm: Double {
        let v = UserDefaults.standard.double(forKey: radiusKey)
        return v > 0 ? min(max(v, 1), 30) : 3
    }

    private static let chunkBytes = 768
    /// Esri World Dark Gray Canvas base tiles: z/y/x (row before column).
    nonisolated static let tileURL =
        "https://server.arcgisonline.com/ArcGIS/rest/services/Canvas/World_Dark_Gray_Base/MapServer/tile/%d/%d/%d"
    /// The local cache is per source, so tiles from another one are never sent.
    nonisolated static let sourceID = "esri-dg1"
    nonisolated static let attribution = "Esri, HERE, Garmin, © OpenStreetMap contributors"

    nonisolated static func url(z: Int, x: Int32, y: Int32) -> URL? {
        URL(string: String(format: tileURL, z, Int(y), Int(x)))
    }

    /// A tile answer worth keeping: HTTP 200 and a JPEG (by type or by its
    /// FF D8 FF start). A placeholder PNG or an error page is not.
    nonisolated static func isTile(_ data: Data, contentType: String?) -> Bool {
        let jpegStart = data.count >= 3 && data[data.startIndex] == 0xFF &&
            data[data.startIndex + 1] == 0xD8 && data[data.startIndex + 2] == 0xFF
        if let t = contentType?.lowercased(), !t.hasPrefix("image/jpeg") { return false }
        return jpegStart
    }

    private enum State { case idle, awaitStat, awaitList, deleting, awaitAck, awaitOk, replacing }
    private var state: State = .idle
    private var center: (lat: Double, lon: Double)?
    private var stat: (total: UInt64, used: UInt64)?
    private var deviceFiles: [String: Int] = [:]
    private var deleteQueue: [String] = []
    /// replaces: the .jpg's size on the board; png: the same tile as a .png
    /// there (CARTO), removed once the .jpg has landed.
    private var sendQueue: [(rel: String, url: URL, replaces: Int?, png: String?)] = []
    private var freeEst: Int64 = 0
    private var sentCount = 0
    private var totalToSend = 0
    private var fileData = Data()
    private var fileOffset = 0
    private var currentRel = ""
    private var currentPng: String?
    private var seq = 0
    private(set) var running = false
    private var timeout: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    /// Where commands go (a test captures them).
    @ObservationIgnored var sendLine: (String) -> Void = { AppModel.shared.serial.send($0) }
    @ObservationIgnored var isConnected: () -> Bool = { AppModel.shared.serialStatus.isConnected }

    private var localRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("Orecchino/tiles-\(Self.sourceID)", isDirectory: true)
    }

    /// The old cache ("Orecchino/tiles", CARTO PNGs: placeholders once CARTO
    /// wanted a key) goes once.
    private func dropOldCache() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = base.appendingPathComponent("Orecchino/tiles", isDirectory: true)
        if FileManager.default.fileExists(atPath: old.path) { try? FileManager.default.removeItem(at: old) }
    }

    nonisolated static func deg2tile(lat: Double, lon: Double, z: Int) -> (x: Int, y: Int) {
        let t = TilePlanner.tileOf(lat: lat, lon: lon, z: z)
        return (Int(t.x), Int(t.y))
    }

    /// Step 1: ask the board, then plan. `around`: this Mac's position (or
    /// the drones'); nil fails with "no position".
    func plan(around c: (lat: Double, lon: Double)?) {
        guard !running else { return }
        guard let c else { phase = .failed("no position for the map"); return }
        guard isConnected() else { phase = .failed("no device"); return }
        running = true
        center = c
        stat = nil
        currentPlan = nil
        deviceFiles = [:]
        state = .awaitStat
        phase = .planning
        send(String(format: #"{"cmd":"fs_stat","lat":%.5f,"lon":%.5f}"#, c.lat, c.lon))
        armTimeout(seconds: 5) { [weak self] in self?.statUnanswered() }
    }

    /// Firmware without fs_stat: plan without a budget, and say so.
    func statUnanswered() {
        guard state == .awaitStat else { return }
        listDevice()
    }

    private func listDevice() {
        state = .awaitList
        send(#"{"cmd":"fs_ls"}"#)
        armTimeout(seconds: 30)
    }

    private func makePlan() {
        timeout?.cancel()
        guard let c = center else { return }
        let disk = Self.diskList(deviceFiles).disk
        let wantM = Self.radiusKm * 1000
        var p: TilePlanner.Plan
        if let st = stat {
            p = TilePlanner.make(lat: c.lat, lon: c.lon, wantM: wantM, fsTotal: st.total, fsUsed: st.used, disk: disk)
            storageKnown = true
            phase = .planned(TilePlanner.describe(p))
        } else {
            // No budget to plan against: the whole circle, and the words say so.
            let used = disk.reduce(UInt64(0)) { $0 + UInt64($1.bytes) }
            p = TilePlanner.make(lat: c.lat, lon: c.lon, wantM: wantM, fsTotal: 1 << 40, fsUsed: used, disk: disk)
            storageKnown = false
            let d = TilePlanner.describe(p)
            let head = d.components(separatedBy: " · ").first ?? d
            phase = .planned(head + String(format: " · %.1f MB, receiver storage unknown",
                                           Double(p.planBytes) / 1048576.0))
        }
        currentPlan = p
        state = .idle
        running = false
    }

    /// Step 2: fetch what the plan needs and push it.
    func send() {
        guard !running, let p = currentPlan else { return }
        running = true
        runTask = Task { await run(p) }
    }

    func start() { plan(around: AppModel.shared.mapCenter) }

    func cancel() {
        runTask?.cancel()   // a download in flight stops, and nothing is sent after it
        runTask = nil
        timeout?.cancel()
        state = .idle
        phase = .idle
        running = false
    }

    private func run(_ p: TilePlanner.Plan) async {
        let tiles = p.allTiles

        // 1. Fill the local cache from Esri (skip anything present).
        dropOldCache()
        var have = 0
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpAdditionalHeaders =
            ["User-Agent": "Orecchino/1.0 (macOS; offline map for an Orecchino receiver; <= 4 tiles/s)"]
        let session = URLSession(configuration: cfg)
        for (i, t) in tiles.enumerated() {
            if Task.isCancelled { return }
            let url = localRoot.appendingPathComponent("\(t.z)/\(t.x)/\(t.y).jpg")
            if FileManager.default.fileExists(atPath: url.path) {
                have += 1
                continue
            }
            phase = .fetching(i, tiles.count)
            guard let remote = Self.url(z: t.z, x: t.x, y: t.y) else { continue }
            do {
                let (data, resp) = try await session.data(from: remote)
                guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                      Self.isTile(data, contentType: http.value(forHTTPHeaderField: "Content-Type"))
                else { continue }
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
        if Task.isCancelled { return }   // cancel() already said idle
        guard have > 0 else {
            phase = .failed("no local tiles")
            running = false
            return
        }
        guard isConnected() else {
            phase = .failed("no device")
            running = false
            return
        }
        buildQueue(p)
        nextDelete()
    }

    /// What to send (plan tiles the board lacks or holds at another size)
    /// and what to evict first (tile_sync_run: only the shortfall, and the
    /// deficit of a board already under the reserve; never inside the plan).
    /// A plan tile the board holds as a .png (CARTO) is sent as a .jpg and
    /// its .png removed once the .jpg has landed (the screens draw the .jpg;
    /// both would be dead weight); a .png beside a current .jpg goes first.
    /// Internal for the tests.
    func buildQueue(_ p: TilePlanner.Plan, localSize: ((URL) -> Int?)? = nil) {
        let fm = FileManager.default
        let size: (URL) -> Int? = localSize ?? { url in
            (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int
        }
        sendQueue = []
        var newBytes: Int64 = 0
        var dupPngs: [String] = []
        var dupBytes: Int64 = 0
        for t in p.allTiles {
            let rel = TilePlanner.path(t.z, t.x, t.y)
            let png = String(rel.dropLast(4)) + ".png"
            let url = localRoot.appendingPathComponent("\(t.z)/\(t.x)/\(t.y).jpg")
            guard let s = size(url) else { continue }
            let onDevice = deviceFiles[rel]
            let pngBytes = deviceFiles[png].map { Int64(Self.onFlash($0)) }
            if onDevice != s {
                sendQueue.append((rel, url, onDevice, pngBytes == nil ? nil : png))
                newBytes += Int64(Self.onFlash(s)) - Int64(onDevice.map(Self.onFlash) ?? 0) - (pngBytes ?? 0)
            } else if let b = pngBytes {
                dupPngs.append(png)
                dupBytes += b
            }
        }
        // The tiles on the board, for victims().
        let (disk, pathsOf) = Self.diskList(deviceFiles)
        let reserve = Int64(TilePlanner.reserve)
        freeEst = (storageKnown ? Int64(p.fsFree) : Int64.max / 4) + dupBytes
        let need = max(newBytes, 0)
        deleteQueue = dupPngs
        // Room for the new tiles over the reserve; under it, the deficit too.
        if storageKnown && need > 0 && need + reserve > freeEst {
            let v = TilePlanner.victims(p, disk, need: UInt64(need + reserve - freeEst))
            deleteQueue += v.indices.flatMap { pathsOf[disk[$0].key] ?? [] }
            freeEst += Int64(v.freed)
        }
        sentCount = 0
        totalToSend = sendQueue.count
    }
    var queuedForTest: (send: [String], delete: [String]) { (sendQueue.map(\.rel), deleteQueue) }
    var replacedForTest: [String] { sendQueue.compactMap(\.png) }

    /// What fs_ls listed, as the planner's sorted list: one entry per tile
    /// (a board may hold a tile as .png and .jpg: its bytes add up, and
    /// evicting it removes both files). Non-tile files (the "/tiles/.src"
    /// mark, strays) are left out.
    nonisolated static func diskList(_ files: [String: Int]) -> (disk: [TilePlanner.OnDisk], paths: [UInt64: [String]]) {
        var bytes: [UInt64: UInt64] = [:]
        var paths: [UInt64: [String]] = [:]
        for (p, s) in files {
            guard let k = TilePlanner.key(path: p) else { continue }
            bytes[k, default: 0] += UInt64(max(s, 0))
            paths[k, default: []].append(p)
        }
        let disk = bytes.map { TilePlanner.OnDisk(key: $0.key, bytes: UInt32(clamping: $0.value)) }
            .sorted { $0.key < $1.key }
        return (disk, paths.mapValues { $0.sorted() })
    }

    /// LittleFS stores a file in 4 KB blocks.
    nonisolated static func onFlash(_ bytes: Int) -> Int { (bytes + 4095) / 4096 * 4096 }

    private func send(_ line: String) {
        sendLine(line)
    }

    private func armTimeout(seconds: Double = 8, onExpiry: (() -> Void)? = nil) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            guard let self, !Task.isCancelled else { return }
            if let onExpiry { onExpiry(); return }
            self.state = .idle
            self.phase = .failed("timeout")
            self.running = false
        }
    }

    /// Routed from AppModel.ingest for fs_*/ack message types. A reply that
    /// does not belong to the current step -- a late ack from an interrupted
    /// session, an fs_ok while idle -- is ignored and leaves the step's
    /// timeout armed, so a stray line can neither advance nor stall a sync.
    func handle(_ msg: RidMessage) {
        switch (msg.type, state) {
        case ("fs_stat", .awaitStat):
            if let t = msg.total, let u = msg.used, t > 0 { stat = (UInt64(t), UInt64(max(u, 0))) }
            listDevice()
        case ("fs_f", .awaitList):
            if let p = msg.p, let s = msg.s { deviceFiles[p] = s }
            armTimeout(seconds: 15)
        case ("fs_ls_done", .awaitList):
            makePlan()
        case ("ack", .awaitAck) where msg.q == nil || msg.q == seq:
            sendNextChunk()
        case ("fs_ok", .deleting):
            nextDelete()
        case ("fs_ok", .awaitOk):
            if let png = currentPng {   // the .jpg landed: its .png goes
                currentPng = nil
                state = .replacing
                send(#"{"cmd":"fs_rm","p":"\#(png)"}"#)
                armTimeout()
                return
            }
            fileSent()
        case ("fs_ok", .replacing):
            fileSent()
        case ("fs_err", _) where running:
            timeout?.cancel()
            state = .idle
            phase = .failed(msg.msg ?? "device error")
            running = false
        default:
            break
        }
    }

    private func fileSent() {
        sentCount += 1
        phase = .syncing(sentCount, totalToSend)
        nextFile()
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
            timeout?.cancel()
            state = .idle
            phase = .done(sentCount, 0)
            running = false
            return
        }
        guard let data = try? Data(contentsOf: item.url) else {
            sendQueue.removeFirst()
            nextFile()
            return
        }
        // Never under the reserve (tile_sync_run): stop and say what is left.
        // A .png it replaces goes right after it: counted as gone.
        let pngBytes = item.png.flatMap { deviceFiles[$0] }.map { Int64(Self.onFlash($0)) } ?? 0
        let grow = Int64(Self.onFlash(data.count)) - Int64(item.replaces.map(Self.onFlash) ?? 0) - pngBytes
        if grow > 0 && freeEst - grow < Int64(TilePlanner.reserve) {
            timeout?.cancel()
            state = .idle
            phase = .done(sentCount, sendQueue.count)
            running = false
            return
        }
        freeEst -= max(grow, 0)
        sendQueue.removeFirst()
        fileData = data
        fileOffset = 0
        seq = 0
        currentRel = item.rel
        currentPng = item.png
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

    private nonisolated static let crcTable: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    nonisolated static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for b in data { crc = crcTable[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFFFFFF
    }
}
