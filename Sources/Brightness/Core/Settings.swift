import Foundation
import Combine
import CoreGraphics

enum BackendKind: String, CaseIterable, Identifiable {
    case overlay
    case gamma

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overlay: return "Multiply Overlay"
        case .gamma:   return "Gamma Table"
        }
    }

    var detail: String {
        switch self {
        case .overlay:
            return "Recommended. Preserves HDR video and leaves no persistent display state."
        case .gamma:
            return "Zero GPU cost, but clips HDR video and conflicts with Night Shift / f.lux."
        }
    }
}

@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let enabled           = "enabled"
        static let brightness        = "brightness"
        static let backend           = "backend"
        static let disableOnBattery  = "disableOnBattery"
        static let disableOnLowPower = "disableOnLowPower"
        static let excluded          = "excludedDisplays"
        static let onboarded         = "hasCompletedOnboarding"
        static let warnConflicts     = "warnOnConflicts"
        static let perDisplay        = "perDisplayBrightness"
        static let backOffVideo      = "backOffDuringVideo"
        static let videoIntensity    = "videoIntensity"
    }

    /// Fires after any change that affects boost output.
    let didChange = PassthroughSubject<Void, Never>()

    private init() {
        defaults.register(defaults: [
            Key.enabled: false,
            Key.brightness: 1.0,
            Key.backend: BackendKind.overlay.rawValue,
            Key.disableOnBattery: false,
            Key.disableOnLowPower: true,
            Key.excluded: [String](),
            Key.perDisplay: [String: Double](),
            Key.backOffVideo: true,
            Key.videoIntensity: 0.0,
            Key.onboarded: false,
            Key.warnConflicts: true,
        ])
        _isEnabled = defaults.bool(forKey: Key.enabled)
        _brightness = defaults.double(forKey: Key.brightness)
        _backend = BackendKind(rawValue: defaults.string(forKey: Key.backend) ?? "") ?? .overlay
        _disableOnBattery = defaults.bool(forKey: Key.disableOnBattery)
        _disableOnLowPower = defaults.bool(forKey: Key.disableOnLowPower)
        _excludedDisplays = Set((defaults.array(forKey: Key.excluded) as? [String] ?? []).compactMap(UInt32.init))
        _hasCompletedOnboarding = defaults.bool(forKey: Key.onboarded)
        _warnOnConflicts = defaults.bool(forKey: Key.warnConflicts)
        _perDisplayBrightness = (defaults.dictionary(forKey: Key.perDisplay) as? [String: Double]) ?? [:]
        _backOffDuringVideo = defaults.bool(forKey: Key.backOffVideo)
        _videoIntensity = defaults.double(forKey: Key.videoIntensity)
    }

    /// SwiftUI requires objectWillChange *before* the value changes.
    private func update(_ body: () -> Void) {
        objectWillChange.send()
        body()
        didChange.send()
    }

    private var _isEnabled: Bool
    var isEnabled: Bool {
        get { _isEnabled }
        set { update { _isEnabled = newValue; defaults.set(newValue, forKey: Key.enabled) } }
    }

    /// 0...1 intensity applied to displays with no value of their own, and to
    /// any display connected from now on. 1.0 == the maximum that display allows.
    ///
    /// Persisted under the original "brightness" key so existing preferences
    /// carry over.
    private var _brightness: Double
    var defaultBrightness: Double {
        get { _brightness }
        set {
            let clamped = min(max(newValue, 0), 1)
            update { _brightness = clamped; defaults.set(clamped, forKey: Key.brightness) }
        }
    }

    /// Per-display overrides, keyed by display ID. Absent means "use the default".
    private var _perDisplayBrightness: [String: Double]

    func brightness(for id: CGDirectDisplayID) -> Double {
        _perDisplayBrightness[String(id)] ?? _brightness
    }

    func hasOwnBrightness(for id: CGDirectDisplayID) -> Bool {
        _perDisplayBrightness[String(id)] != nil
    }

    func setBrightness(_ value: Double, for id: CGDirectDisplayID) {
        let clamped = min(max(value, 0), 1)
        update {
            _perDisplayBrightness[String(id)] = clamped
            defaults.set(_perDisplayBrightness, forKey: Key.perDisplay)
        }
    }

    /// Drop the override so this display follows `defaultBrightness` again.
    func clearBrightness(for id: CGDirectDisplayID) {
        guard _perDisplayBrightness[String(id)] != nil else { return }
        update {
            _perDisplayBrightness.removeValue(forKey: String(id))
            defaults.set(_perDisplayBrightness, forKey: Key.perDisplay)
        }
    }

    /// Nudge every given display, materialising an override for each so the
    /// hotkeys behave predictably on mixed setups.
    func nudgeBrightness(by delta: Double, for ids: [CGDirectDisplayID]) {
        guard !ids.isEmpty else { return }
        update {
            for id in ids {
                let current = _perDisplayBrightness[String(id)] ?? _brightness
                _perDisplayBrightness[String(id)] = min(max(current + delta, 0), 1)
            }
            defaults.set(_perDisplayBrightness, forKey: Key.perDisplay)
        }
    }

    private var _backend: BackendKind
    var backend: BackendKind {
        get { _backend }
        set { update { _backend = newValue; defaults.set(newValue.rawValue, forKey: Key.backend) } }
    }

    private var _disableOnBattery: Bool
    var disableOnBattery: Bool {
        get { _disableOnBattery }
        set { update { _disableOnBattery = newValue; defaults.set(newValue, forKey: Key.disableOnBattery) } }
    }

    private var _disableOnLowPower: Bool
    var disableOnLowPower: Bool {
        get { _disableOnLowPower }
        set { update { _disableOnLowPower = newValue; defaults.set(newValue, forKey: Key.disableOnLowPower) } }
    }

    private var _excludedDisplays: Set<CGDirectDisplayID>
    var excludedDisplays: Set<CGDirectDisplayID> {
        get { _excludedDisplays }
        set {
            update {
                _excludedDisplays = newValue
                defaults.set(newValue.map(String.init), forKey: Key.excluded)
            }
        }
    }

    private var _hasCompletedOnboarding: Bool
    var hasCompletedOnboarding: Bool {
        get { _hasCompletedOnboarding }
        set { update { _hasCompletedOnboarding = newValue; defaults.set(newValue, forKey: Key.onboarded) } }
    }

    private var _warnOnConflicts: Bool
    var warnOnConflicts: Bool {
        get { _warnOnConflicts }
        set { update { _warnOnConflicts = newValue; defaults.set(newValue, forKey: Key.warnConflicts) } }
    }

    /// Ease off while video is playing, so HDR highlights are not multiplied
    /// past the panel's ceiling and clipped.
    private var _backOffDuringVideo: Bool
    var backOffDuringVideo: Bool {
        get { _backOffDuringVideo }
        set { update { _backOffDuringVideo = newValue; defaults.set(newValue, forKey: Key.backOffVideo) } }
    }

    /// Intensity used while video plays. 0 means no boost at all.
    private var _videoIntensity: Double
    var videoIntensity: Double {
        get { _videoIntensity }
        set {
            let clamped = min(max(newValue, 0), 1)
            update { _videoIntensity = clamped; defaults.set(clamped, forKey: Key.videoIntensity) }
        }
    }

    func isExcluded(_ id: CGDirectDisplayID) -> Bool { excludedDisplays.contains(id) }

    func setExcluded(_ excluded: Bool, for id: CGDirectDisplayID) {
        var set = excludedDisplays
        if excluded { set.insert(id) } else { set.remove(id) }
        excludedDisplays = set
    }
}
