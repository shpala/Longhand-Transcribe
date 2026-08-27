import CoreLocation
import LonghandKit

/// One-shot capture of "where was this recorded" at record start. Shared by
/// the iOS and macOS shells (CoreLocation behaves the same on both; on the
/// Mac the fix comes from Wi-Fi positioning). Deliberate
/// non-features: no continuous updates, no geocoding (reverse geocoding sends
/// coordinates to Apple's servers; the raw fix stays on-device), and a
/// failure is always just nil, never an error the recording flow can trip on.
public nonisolated final class LocationCapture: NSObject, CLLocationManagerDelegate, @unchecked Sendable {

    public static let settingsKey = "captureLocation"

    /// The Settings toggle. **Off unless asked for**: a recording's location
    /// is the kind of thing that should be a decision, not a default, even
    /// though it never leaves the device (§14.1), and a feature nobody opted
    /// into is a feature nobody expects to be there.
    public static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: settingsKey) as? Bool ?? false
    }

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CapturedLocation?, Never>?
    private let lock = NSLock()

    /// Requests when-in-use authorization if needed and resolves a single
    /// fix, or nil on denial/timeout/no-signal. Safe to race with recording:
    /// callers fire this in parallel and attach the result at save time.
    public override init() { super.init() }

    public func capture() async -> CapturedLocation? {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        let status = manager.authorizationStatus
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
            // The delegate resumes the flow from locationManagerDidChangeAuthorization.
        } else if !Self.isAuthorized(status) {
            return nil
        }
        return await withCheckedContinuation { cont in
            lock.lock()
            // Resolve any earlier waiter rather than stranding it: a second
            // capture used to leak the first continuation and its watchdog.
            let previous = continuation
            continuation = cont
            lock.unlock()
            previous?.resume(returning: nil)
            if Self.isAuthorized(status) {
                manager.requestLocation()
            }
            // Belt-and-braces: never leave the save path waiting on CoreLocation.
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) { [weak self] in
                self?.finish(with: nil)
            }
        }
    }

    /// macOS has no `.authorizedWhenInUse` (a when-in-use grant reports as
    /// `.authorizedAlways` there), so the check can't be one shared case list.
    private static func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
        #if os(macOS)
        return status == .authorizedAlways
        #else
        return status == .authorizedWhenInUse || status == .authorizedAlways
        #endif
    }

    private func finish(with location: CapturedLocation?) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: location)
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        if Self.isAuthorized(status) {
            manager.requestLocation()
        } else if status == .notDetermined {
            return   // prompt still up
        } else {
            finish(with: nil)
        }
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last else { finish(with: nil); return }
        finish(with: CapturedLocation(latitude: fix.coordinate.latitude,
                                      longitude: fix.coordinate.longitude,
                                      horizontalAccuracyMeters: fix.horizontalAccuracy >= 0
                                          ? fix.horizontalAccuracy : nil))
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(with: nil)
    }
}
