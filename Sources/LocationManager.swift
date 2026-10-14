import Foundation
import CoreLocation

// ── GPS vom iPhone: Tempo und Position fuer den Fahrtenschreiber ──
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var speedKmh: Double?
    @Published private(set) var location: CLLocation?
    @Published private(set) var denied = false

    private let manager = CLLocationManager()

    /// An, solange aufgezeichnet wird oder ein Geraet verbunden ist (spart Akku)
    var enabled = false {
        didSet { if enabled != oldValue { apply() } }
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .automotiveNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
    }

    /// Beim ersten Start fragen, nicht erst im Auto
    func requestPermissionIfNeeded() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    /// Letzte Position, wenn sie frisch und genau genug ist
    var freshLocation: CLLocation? {
        guard let l = location, Date().timeIntervalSince(l.timestamp) < 5 else { return nil }
        return l
    }

    private func apply() {
        guard enabled else {
            manager.stopUpdatingLocation()
            speedKmh = nil
            location = nil
            return
        }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            denied = true
        default:
            denied = false
            // laeuft auch bei gesperrtem Bildschirm weiter (Hintergrundmodus "location")
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
            manager.startUpdatingLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        apply()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last, l.horizontalAccuracy >= 0, l.horizontalAccuracy < 50 else { return }
        location = l
        speedKmh = l.speed >= 0 ? l.speed * 3.6 : nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        speedKmh = nil
    }
}
