import AppKit

/// Backends are deliberately dumb: they know how to apply a gain and how to
/// stop cleanly. Only `BoostCoordinator` decides whether boost should be on.
@MainActor
protocol BrightnessBackend: AnyObject {
    var kind: BackendKind { get }
    var isActive: Bool { get }

    /// Idempotent. Called on enable and whenever display topology changes.
    func activate(on displays: [BoostDisplay])

    /// Must fully restore every display it touched.
    func deactivate()

    func setGain(_ gain: Double, for displayID: CGDirectDisplayID)

    func displaysChanged(_ displays: [BoostDisplay])

    /// Periodic integrity check — used by the gamma watchdog.
    func poll()
}

extension BrightnessBackend {
    func poll() {}
}
