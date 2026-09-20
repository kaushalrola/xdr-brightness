import AppKit
import IOKit.ps

@MainActor
final class PowerPolicy {
    private(set) var isOnBattery = false
    private(set) var isLowPower = false

    var onChange: (() -> Void)?

    private var lastBatteryCheck = Date.distantPast

    func start() {
        isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        refreshBattery(force: true)

        NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = ProcessInfo.processInfo.isLowPowerModeEnabled
                guard now != self.isLowPower else { return }
                self.isLowPower = now
                log("PowerPolicy: low power mode \(now ? "on" : "off")")
                self.onChange?()
            }
        }
    }

    /// Polled from the coordinator tick; throttled since it allocates.
    func refreshBattery(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastBatteryCheck) > 5 else { return }
        lastBatteryCheck = Date()

        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeRetainedValue() as String?
        else { return }

        let onBattery = (type == kIOPSBatteryPowerValue)
        guard onBattery != isOnBattery else { return }
        isOnBattery = onBattery
        log("PowerPolicy: now on \(onBattery ? "battery" : "AC")")
        onChange?()
    }

    /// Whether power conditions currently forbid boosting.
    var shouldSuppressBoost: Bool {
        let settings = Settings.shared
        if settings.disableOnBattery && isOnBattery { return true }
        if settings.disableOnLowPower && isLowPower { return true }
        return false
    }

    var suppressionReason: String? {
        let settings = Settings.shared
        if settings.disableOnBattery && isOnBattery { return "Paused on battery" }
        if settings.disableOnLowPower && isLowPower { return "Paused in Low Power Mode" }
        return nil
    }
}
