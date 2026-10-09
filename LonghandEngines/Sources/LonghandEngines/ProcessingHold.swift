import Foundation
import LonghandKit

/// A reason the library should not be running a pipeline right now, decided
/// from what the system says about power and heat.
///
/// Transcription is minutes of sustained Neural Engine and CPU work. In Low
/// Power Mode the user has asked the phone to go easy, and a serious thermal
/// state is the system saying the same. Rather than run slowly and hot, the
/// library stops its jobs at the next checkpoint and picks them up when the
/// condition lifts, saying so on the row, since a job that stops for no
/// visible reason reads as a bug.
public enum ProcessingHold: Equatable, Sendable {
    case lowPowerMode
    case thermal

    public static let lowPowerKey = "pauseInLowPowerMode"

    /// The Settings toggle. **On by default**: Low Power Mode is a request
    /// the user already made, and this honours it. The thermal hold has no
    /// toggle; a phone at "serious" is not a matter of preference.
    public static var pausesInLowPowerMode: Bool {
        UserDefaults.standard.object(forKey: lowPowerKey) as? Bool ?? true
    }

    /// Pure, so the decision is testable without a hot phone.
    public static func current(lowPowerMode: Bool, thermalState: ProcessInfo.ThermalState,
                               pausesInLowPowerMode: Bool) -> ProcessingHold? {
        switch thermalState {
        case .serious, .critical:
            return .thermal
        default:
            break
        }
        if lowPowerMode && pausesInLowPowerMode { return .lowPowerMode }
        return nil
    }

    /// What the system reports right now.
    public static func current() -> ProcessingHold? {
        let info = ProcessInfo.processInfo
        return current(lowPowerMode: info.isLowPowerModeEnabled, thermalState: info.thermalState,
                       pausesInLowPowerMode: pausesInLowPowerMode)
    }

    /// For the row and the transcript screen.
    public var message: String {
        switch self {
        case .lowPowerMode: "Waiting for Low Power Mode to end"
        case .thermal: "Waiting for the device to cool down"
        }
    }

    public var symbolName: String {
        switch self {
        case .lowPowerMode: "battery.25percent"
        case .thermal: "thermometer.high"
        }
    }
}
