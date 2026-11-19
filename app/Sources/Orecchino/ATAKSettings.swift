// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

@MainActor
struct ATAKSettings: View {
    @Environment(AppModel.self) private var model
    @State private var host = ""
    @State private var port = String(ATAKEndpoint.defaultPort)

    var body: some View {
        let service = model.atak
        Section("ATAK · UDP") {
            TextField("ATAK device host or IP", text: $host)
            TextField("UDP port", text: $port)
            Button("Save Destination") { service.saveDestination(host: host, port: port) }
            Toggle("Send live drone positions to ATAK", isOn: Binding(
                get: { service.enabled },
                set: { service.setEnabled($0) }
            ))
            .disabled(service.endpoint == nil)
            Text("Use the ATAK device’s address and UDP input port, usually 4242. When enabled, Orecchino sends detected drone positions over the network.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let destination = service.endpoint {
                Text("Saved destination: \(destination.display)")
                    .font(.caption)
                    .textSelection(.enabled)
            }
            if let error = service.settingsError {
                Text(error).font(.caption).foregroundStyle(Theme.warn)
            }
            Text(status(service))
                .font(.caption)
                .foregroundStyle(service.networkError == nil ? Theme.muted : Theme.warn)
                .textSelection(.enabled)
        }
        .onAppear { load(service.endpoint) }
        .onChange(of: service.endpoint) { _, endpoint in load(endpoint) }
    }

    private func load(_ endpoint: ATAKEndpoint?) {
        host = endpoint?.host ?? ""
        port = String(endpoint?.port ?? ATAKEndpoint.defaultPort)
    }

    private func status(_ service: ATAKService) -> String {
        guard service.enabled else { return "ATAK output is off." }
        if let error = service.networkError { return "UDP send error: \(error)" }
        if let sent = service.lastSent {
            return "Last datagram sent locally at \(sent.formatted(date: .omitted, time: .standard)). "
                + "\(service.datagramsSent) sent. UDP provides no delivery acknowledgement."
        }
        if service.isConnecting { return "Opening the ATAK UDP output…" }
        return "Waiting for a fresh drone position."
    }
}
