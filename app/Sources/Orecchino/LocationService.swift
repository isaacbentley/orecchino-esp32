import CoreLocation
import Observation

/// Coarse operator location, pushed to the receiver for ranging readouts.
@MainActor
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    private let mgr = CLLocationManager()
    var current: CLLocationCoordinate2D?

    override init() {
        super.init()
        mgr.delegate = self
        mgr.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func start() {
        mgr.requestWhenInUseAuthorization()
        mgr.startUpdatingLocation()
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        let c = locations.last?.coordinate
        Task { @MainActor in
            let hadNone = self.current == nil
            self.current = c
            // First fix after launch: refresh the device context with it.
            if hadNone, c != nil { AppModel.shared.deviceCtxPushed = false }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {}
}
