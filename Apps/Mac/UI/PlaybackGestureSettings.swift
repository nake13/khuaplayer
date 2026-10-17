import Foundation

enum SPPlaybackGestureSettings {
    enum PinchAction: Int {
        case resizeWindow = 0
        case fullscreen = 1
        case disabled = 2
    }

    enum Sensitivity: Int {
        case low = 0
        case normal = 1
        case high = 2

        var multiplier: Double {
            switch self {
            case .low: return 0.5
            case .normal: return 1
            case .high: return 2
            }
        }
    }

    static let changed = Notification.Name("sp.playbackGestureChanged")

    private static let horizontalSeekKey = "playbackGesture.horizontalSeekEnabled"
    private static let verticalVolumeKey = "playbackGesture.verticalVolumeEnabled"
    private static let pinchActionKey = "playbackGesture.pinchAction"
    private static let sensitivityKey = "playbackGesture.sensitivity"

    static var horizontalSeekEnabled: Bool {
        get { UserDefaults.standard.object(forKey: horizontalSeekKey) as? Bool ?? true }
        set {
            guard newValue != horizontalSeekEnabled else { return }
            store(newValue, forKey: horizontalSeekKey)
        }
    }

    static var verticalVolumeEnabled: Bool {
        get { UserDefaults.standard.object(forKey: verticalVolumeKey) as? Bool ?? true }
        set {
            guard newValue != verticalVolumeEnabled else { return }
            store(newValue, forKey: verticalVolumeKey)
        }
    }

    static var pinchAction: PinchAction {
        get {
            guard let raw = UserDefaults.standard.object(forKey: pinchActionKey) as? Int,
                  let action = PinchAction(rawValue: raw) else { return .resizeWindow }
            return action
        }
        set {
            guard newValue != pinchAction else { return }
            store(newValue.rawValue, forKey: pinchActionKey)
        }
    }

    static var sensitivity: Sensitivity {
        get {
            guard let raw = UserDefaults.standard.object(forKey: sensitivityKey) as? Int,
                  let value = Sensitivity(rawValue: raw) else { return .normal }
            return value
        }
        set {
            guard newValue != sensitivity else { return }
            store(newValue.rawValue, forKey: sensitivityKey)
        }
    }

    private static func store(_ value: Any, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
        NotificationCenter.default.post(name: changed, object: nil)
    }
}
