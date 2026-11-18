import CoreLocation
import Observation

/// This Mac's location: pushed to the receiver for ranging, the reference
/// for TFRs and ADS-B, and the traffic rules' observer. Says why it has none
/// (permission denied, not determined, or no fix) rather than going quiet.
@MainActor
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    enum Access: Equatable {
        /// denied also covers Location Services being off for the whole Mac.
        case notDetermined, denied, restricted, authorized
    }

    private let mgr = CLLocationManager()
    var current: CLLocationCoordinate2D?
    var currentLocation: CLLocation?
    var access: Access = .notDetermined
    /// The last Core Location error, until the next fix.
    var lastError: String?

    override init() {
        super.init()
        mgr.delegate = self
        mgr.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func start() {
        mgr.requestWhenInUseAuthorization()
        mgr.startUpdatingLocation()
        noteAuthorization(mgr.authorizationStatus)
    }

    /// One line for the status strip when there is no usable position; nil
    /// when there is one.
    var problem: String? {
        if current != nil { return nil }
        switch access {
        case .denied:        return "location denied"
        case .restricted:    return "location restricted"
        case .notDetermined: return "location not allowed yet"
        case .authorized:    return lastError.map { _ in "no location fix" } ?? "locating…"
        }
    }

    var problemHelp: String {
        switch access {
        case .denied, .restricted:
            return "Allow Orecchino in System Settings › Privacy & Security › Location Services. "
                + "Without it there is no range to drones, TFRs and ADS-B are looked up around "
                + "the drones instead, and nothing is looked up before a drone reports a position."
        default:
            return lastError ?? "Waiting for this Mac's first position."
        }
    }

    private func noteAuthorization(_ s: CLAuthorizationStatus) {
        let a: Access
        switch s {
        case .notDetermined: a = .notDetermined
        case .denied:        a = .denied
        case .restricted:    a = .restricted
        default:             a = .authorized
        }
        if a != access { access = a }
        if a == .denied || a == .restricted {
            current = nil
            currentLocation = nil
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        Task { @MainActor in
            self.noteAuthorization(s)
            if self.access == .authorized { self.mgr.startUpdatingLocation() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            let hadNone = self.current == nil
            self.current = loc.coordinate
            self.currentLocation = loc
            self.lastError = nil
            // First fix after launch: refresh the device context with it.
            if hadNone { AppModel.shared.deviceCtxPushed = false }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        let code = (error as? CLError)?.code
        let text = error.localizedDescription
        Task { @MainActor in
            if code == .denied {
                self.noteAuthorization(.denied)
            } else if code != .locationUnknown {   // "unknown" is transient: keep trying
                self.lastError = text
            }
        }
    }
}
