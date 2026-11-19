// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Network
import Observation

@MainActor
@Observable
final class ATAKService {
    private struct Stored: Codable {
        let enabled: Bool
        let host: String
        let port: Int
    }

    private static let defaultsKey = "atakUDPOutput"
    private static let reconnectDelay: TimeInterval = 3

    private(set) var enabled = false
    private(set) var endpoint: ATAKEndpoint?
    private(set) var isConnecting = false
    private(set) var lastSent: Date?
    private(set) var datagramsSent = 0
    private(set) var networkError: String?
    private(set) var settingsError: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let session = UUID().uuidString
        .replacingOccurrences(of: "-", with: "").lowercased()
    @ObservationIgnored private let queue = DispatchQueue(label: "orecchino.atak.udp")
    @ObservationIgnored private var connection: NWConnection?
    @ObservationIgnored private var resolution: Task<Void, Never>?
    @ObservationIgnored private var connectAfter = Date.distantPast
    @ObservationIgnored private var connectionVersion = 0
    @ObservationIgnored private var ready = false
    @ObservationIgnored private var inFlight = 0
    @ObservationIgnored private var sendPlan = ATAKSendPlan()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode(Stored.self, from: data),
           let destination = try? ATAKEndpoint(host: saved.host, port: saved.port) {
            endpoint = destination
            enabled = saved.enabled
        }
    }

    func saveDestination(host: String, port: String) {
        do {
            guard let number = Int(port.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw ATAKError.port
            }
            let value = try ATAKEndpoint(host: host, port: number)
            if value != endpoint { try apply(enabled: enabled, endpoint: value) }
            settingsError = nil
        } catch {
            settingsError = error.localizedDescription
        }
    }

    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        do {
            guard let endpoint else { throw ATAKError.host }
            try apply(enabled: value, endpoint: endpoint)
            settingsError = nil
        } catch {
            settingsError = error.localizedDescription
        }
    }

    private func apply(enabled: Bool, endpoint: ATAKEndpoint) throws {
        let data = try JSONEncoder().encode(Stored(enabled: enabled, host: endpoint.host, port: endpoint.port))
        defaults.set(data, forKey: Self.defaultsKey)
        self.enabled = enabled
        self.endpoint = endpoint
        resetConnection()
        connectAfter = .distantPast
        sendPlan = ATAKSendPlan()
        datagramsSent = 0
        lastSent = nil
        networkError = nil
    }

    /// Triggered by AppModel's shared 2 Hz clock. Queues only a bounded
    /// batch and leaves newer fixes in the track table until a slot opens.
    func publish(_ samples: [ATAKSample], at now: Date) {
        guard enabled, let endpoint else { return }
        if connection == nil, resolution == nil, now >= connectAfter,
           samples.contains(where: { $0.fix.fresh(at: now) }) {
            connect(endpoint)
            return
        }
        guard ready, let connection, inFlight == 0 else { return }

        let batch = sendPlan.batch(samples, at: now)
        let version = connectionVersion
        for sample in batch {
            guard let xml = ATAKCoT.event(sample, session: session, at: now) else { continue }
            inFlight += 1
            connection.send(content: xml, completion: .contentProcessed { [weak self] error in
                Task { @MainActor [weak self] in
                    self?.didSend(sample, error: error, version: version)
                }
            })
        }
    }

    private func connect(_ target: ATAKEndpoint) {
        let version = connectionVersion
        isConnecting = true
        resolution = Task { [weak self] in
            do {
                let ip = try await Task.detached(priority: .utility) { try target.resolve() }.value
                guard let self, connectionVersion == version else { return }
                resolution = nil
                guard let port = NWEndpoint.Port(rawValue: UInt16(target.port)) else {
                    fail(ATAKError.port)
                    return
                }
                let connection = NWConnection(host: NWEndpoint.Host(ip), port: port, using: .udp)
                self.connection = connection
                connection.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor [weak self] in
                        guard let self, connectionVersion == version else { return }
                        connectionDidChange(state)
                    }
                }
                connection.start(queue: queue)
            } catch {
                guard let self, connectionVersion == version else { return }
                fail(error)
            }
        }
    }

    private func connectionDidChange(_ state: NWConnection.State) {
        switch state {
        case .ready:
            ready = true
            isConnecting = false
            networkError = nil
        case .waiting(let error), .failed(let error):
            fail(error)
        case .cancelled:
            resetConnection()
            connectAfter = Date().addingTimeInterval(Self.reconnectDelay)
        default:
            break
        }
    }

    private func didSend(_ sample: ATAKSample, error: NWError?, version: Int) {
        guard enabled, connectionVersion == version else { return }
        inFlight = max(0, inFlight - 1)
        if let error {
            networkError = error.localizedDescription
        } else {
            sendPlan.sent(sample)
            lastSent = Date()
            datagramsSent += 1
            networkError = nil
        }
    }

    private func fail(_ error: Error) {
        resetConnection()
        connectAfter = Date().addingTimeInterval(Self.reconnectDelay)
        networkError = error.localizedDescription
    }

    private func resetConnection() {
        connectionVersion &+= 1
        resolution?.cancel()
        resolution = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        ready = false
        isConnecting = false
        inFlight = 0
    }
}
