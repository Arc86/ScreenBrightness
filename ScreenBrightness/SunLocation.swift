import CoreLocation
import Observation

/// Where the Mac is, roughly, for sunrise and sunset. Located once and remembered,
/// then refreshed every few days in case the Mac moved.
@MainActor
@Observable
final class SunLocation: NSObject, CLLocationManagerDelegate {
    enum Status: Equatable {
        case idle, locating, denied, failed
    }

    private(set) var coordinate: Coordinate?
    private(set) var status: Status = .idle
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private var manager: CLLocationManager?
    @ObservationIgnored private var locatedAt: Date?

    private static let storageKey = "sunLocation"
    private static let dateKey = "sunLocationDate"
    private static let refreshInterval: TimeInterval = 3 * 24 * 60 * 60

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: Self.storageKey) {
            coordinate = try? JSONDecoder().decode(Coordinate.self, from: data)
        }
        locatedAt = UserDefaults.standard.object(forKey: Self.dateKey) as? Date
    }

    /// Locates the Mac if there is no location yet or the last one is a few days old.
    func updateIfNeeded() {
        guard status != .locating else { return }
        if let locatedAt, coordinate != nil, Date.now.timeIntervalSince(locatedAt) < Self.refreshInterval { return }
        locate()
    }

    func locate() {
        let manager = self.manager ?? CLLocationManager()
        self.manager = manager
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced
        switch manager.authorizationStatus {
        case .notDetermined:
            status = .locating
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            status = .denied
        default:
            status = .locating
            manager.requestLocation()
        }
    }

    private func store(_ location: CLLocation) {
        // Two decimals is about a kilometre: plenty for sunrise and sunset.
        let rounded = Coordinate(latitude: (location.coordinate.latitude * 100).rounded() / 100,
                                 longitude: (location.coordinate.longitude * 100).rounded() / 100)
        status = .idle
        locatedAt = .now
        UserDefaults.standard.set(Date.now, forKey: Self.dateKey)
        guard rounded != coordinate else { return }
        coordinate = rounded
        UserDefaults.standard.set(try? JSONEncoder().encode(rounded), forKey: Self.storageKey)
        onChange?()
    }

    // The manager is created on the main thread, so its delegate calls arrive there too.

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let authorization = manager.authorizationStatus
        MainActor.assumeIsolated {
            guard status == .locating || status == .denied else { return }
            switch authorization {
            case .notDetermined: break
            case .denied, .restricted: status = .denied
            default:
                status = .locating
                self.manager?.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        MainActor.assumeIsolated { store(location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        MainActor.assumeIsolated {
            status = .failed
        }
    }
}
