import CoreLocation
import Foundation

/// One-shot "where was this recorded" on the wrist.
///
/// A near-twin of `LocationCapture` in LonghandEngines, duplicated rather than
/// shared because that package cannot build for watchOS (it links WhisperKit
/// and SpeakerKit, which have no watch support) and the watch target links
/// nothing. The behaviour is deliberately identical: no continuous updates, no
/// geocoding (that would send coordinates to a network service), and any
/// failure is nil rather than something the recording flow can trip over.
///
/// Series 7 has no GPS of its own; CoreLocation answers from the paired
/// iPhone when it is in range, and from Wi-Fi otherwise. Either is good enough
/// for "which meeting was this".
nonisolated final class WatchLocationCapture: NSObject, CLLocationManagerDelegate, @unchecked Sendable {

    struct Fix: Sendable {
        let latitude: Double
        let longitude: Double
        let accuracy: Double?
    }

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<Fix?, Never>?
    private let lock = NSLock()

    func capture() async -> Fix? {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        let status = manager.authorizationStatus
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
            // The delegate resumes this from locationManagerDidChangeAuthorization.
        } else if !Self.isAuthorized(status) {
            return nil
        }
        return await withCheckedContinuation { continuation in
            lock.lock()
            // A second capture on the same object would strand the first
            // continuation forever: a leaked task and a recording that never
            // learns its answer. Resolve the old one instead.
            let previous = self.continuation
            self.continuation = continuation
            lock.unlock()
            previous?.resume(returning: nil)
            if Self.isAuthorized(status) {
                manager.requestLocation()
            }
            // Never leave a recording waiting on CoreLocation.
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) { [weak self] in
                self?.finish(with: nil)
            }
        }
    }

    private static func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
        status == .authorizedWhenInUse || status == .authorizedAlways
    }

    private func finish(with fix: Fix?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: fix)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        if Self.isAuthorized(status) {
            manager.requestLocation()
        } else if status == .notDetermined {
            return   // prompt still up
        } else {
            finish(with: nil)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last else { finish(with: nil); return }
        finish(with: Fix(latitude: fix.coordinate.latitude,
                         longitude: fix.coordinate.longitude,
                         accuracy: fix.horizontalAccuracy >= 0 ? fix.horizontalAccuracy : nil))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(with: nil)
    }
}
