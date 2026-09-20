import AppKit

/// Zero-GPU alternative. Amplifies via the display transfer table.
///
/// Gamma alone cannot exceed the SDR ceiling, so a 1x1 EDR trigger window is
/// still required to hold the headroom open — gamma then does the amplifying.
///
/// Drawbacks, disclosed in the UI: clips HDR video, fights Night Shift / f.lux,
/// and needs a watchdog because macOS silently resets the table.
@MainActor
final class GammaBackend: BrightnessBackend {
    let kind: BackendKind = .gamma
    private(set) var isActive = false

    private var captured: [CGDirectDisplayID: GammaTable] = [:]
    private var appliedGain: [CGDirectDisplayID: Double] = [:]
    private var triggers: [CGDirectDisplayID: OverlayWindowController] = [:]
    private weak var registry: DisplayRegistry?

    /// Tolerance before we consider the table to have drifted.
    private let driftTolerance: Double = 0.01

    init(registry: DisplayRegistry) {
        self.registry = registry
    }

    func activate(on displays: [BoostDisplay]) {
        isActive = true
        sync(to: displays)
    }

    func deactivate() {
        guard isActive || !captured.isEmpty else { return }
        isActive = false

        for (id, table) in captured {
            table.apply(to: id, gain: 1.0)
            log("GammaBackend: restored gamma for display \(id)")
        }
        captured.removeAll()
        appliedGain.removeAll()

        for (_, trigger) in triggers { trigger.close() }
        triggers.removeAll()

        // Authoritative reset in case a table failed to restore cleanly.
        SafetyNet.restoreNow()
    }

    func displaysChanged(_ displays: [BoostDisplay]) {
        guard isActive else { return }
        sync(to: displays)
    }

    func setGain(_ gain: Double, for displayID: CGDirectDisplayID) {
        guard let table = captured[displayID] else { return }
        guard table.apply(to: displayID, gain: gain) else { return }
        appliedGain[displayID] = gain
    }

    /// Drift watchdog. macOS resets gamma on wake, reconfiguration, and user
    /// brightness changes. Frequent drift is the signature of a conflicting app.
    func poll() {
        guard isActive else { return }

        for (id, table) in captured {
            guard let gain = appliedGain[id], gain > 1.0 else { continue }
            guard let current = GammaTable.capture(displayID: id) else { continue }

            let expected = table.endpoint
            let actual = current.endpoint
            let drifted =
                abs(actual.0 - expected.0 * gain) > driftTolerance ||
                abs(actual.1 - expected.1 * gain) > driftTolerance ||
                abs(actual.2 - expected.2 * gain) > driftTolerance

            if drifted {
                log(String(format: "GammaBackend: drift on display %u (expected %.3f, saw %.3f) — reapplying",
                           id, expected.0 * gain, actual.0))
                table.apply(to: id, gain: gain)
            }
        }
    }

    private func sync(to displays: [BoostDisplay]) {
        let wanted = Set(displays.map(\.id))

        for id in captured.keys where !wanted.contains(id) {
            captured[id]?.apply(to: id, gain: 1.0)
            captured.removeValue(forKey: id)
            appliedGain.removeValue(forKey: id)
        }
        for id in triggers.keys where !wanted.contains(id) {
            triggers[id]?.close()
            triggers.removeValue(forKey: id)
        }

        for display in displays {
            guard let screen = registry?.screen(for: display.id) else { continue }

            if captured[display.id] == nil {
                // Capture the untouched table exactly once, before we modify it.
                if let table = GammaTable.capture(displayID: display.id) {
                    captured[display.id] = table
                    log("GammaBackend: captured baseline gamma for display \(display.id)")
                }
            }

            if let existing = triggers[display.id] {
                existing.update(on: screen)
            } else {
                // A bright single pixel is enough to keep EDR engaged.
                let trigger = OverlayWindowController(displayID: display.id, role: .trigger, gain: 2.0)
                triggers[display.id] = trigger
                trigger.open(on: screen)
                log("GammaBackend: created EDR trigger for display \(display.id)")
            }
        }
    }
}
