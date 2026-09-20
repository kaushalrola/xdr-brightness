import AppKit

/// The default backend. A multiply-composited EDR layer over each display.
///
/// Inherently safe: if the process dies the windows die with it, so there is
/// no persistent state that can strand a display.
@MainActor
final class OverlayBackend: BrightnessBackend {
    let kind: BackendKind = .overlay
    private(set) var isActive = false

    private var controllers: [CGDirectDisplayID: OverlayWindowController] = [:]
    private weak var registry: DisplayRegistry?

    init(registry: DisplayRegistry) {
        self.registry = registry
    }

    func activate(on displays: [BoostDisplay]) {
        isActive = true
        sync(to: displays)
    }

    func deactivate() {
        guard isActive || !controllers.isEmpty else { return }
        isActive = false
        for (id, controller) in controllers {
            controller.close()
            log("OverlayBackend: closed overlay for display \(id)")
        }
        controllers.removeAll()
    }

    func displaysChanged(_ displays: [BoostDisplay]) {
        guard isActive else { return }
        sync(to: displays)
    }

    private var lastGain: [CGDirectDisplayID: Double] = [:]

    func setGain(_ gain: Double, for displayID: CGDirectDisplayID) {
        controllers[displayID]?.setGain(gain)
        if abs((lastGain[displayID] ?? 0) - gain) > 0.0005 {
            log(String(format: "OverlayBackend: display %u gain -> %.4f", displayID, gain))
            lastGain[displayID] = gain
        }
    }

    private func sync(to displays: [BoostDisplay]) {
        let wanted = Set(displays.map(\.id))

        for (id, controller) in controllers where !wanted.contains(id) {
            controller.close()
            controllers.removeValue(forKey: id)
            log("OverlayBackend: removed overlay for departed display \(id)")
        }

        for display in displays {
            guard let screen = registry?.screen(for: display.id) else { continue }
            if let existing = controllers[display.id] {
                existing.update(on: screen)
            } else {
                // Start at 1.0 (no visible change) and let the coordinator ramp
                // it up once headroom is confirmed.
                let controller = OverlayWindowController(displayID: display.id, role: .multiply, gain: 1.0)
                controllers[display.id] = controller
                controller.open(on: screen)
                log("OverlayBackend: created overlay for display \(display.id) (\(display.name))")
            }
        }
    }

    var diagnostics: String {
        controllers.map { "  display \($0.key): \($0.value.stats)" }.sorted().joined(separator: "\n")
    }
}
