import AppKit

extension Notification.Name {
    static let displayTopologyChanged = Notification.Name("app.brightness.displayTopologyChanged")
}

/// C callback — cannot capture context, so it just posts a notification.
private func displayReconfigured(
    _ display: CGDirectDisplayID,
    _ flags: CGDisplayChangeSummaryFlags,
    _ userInfo: UnsafeMutableRawPointer?
) {
    // Ignore the "before the change" pass; act only on the settled state.
    guard !flags.contains(.beginConfigurationFlag) else { return }
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: .displayTopologyChanged, object: nil)
    }
}

@MainActor
final class DisplayRegistry {
    private(set) var displays: [BoostDisplay] = []
    var onChange: (([BoostDisplay]) -> Void)?

    func start() {
        CGDisplayRegisterReconfigurationCallback(displayReconfigured, nil)

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }

        NotificationCenter.default.addObserver(
            forName: .displayTopologyChanged,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }

        refresh()
    }

    func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { $0.displayID == id }
    }

    func refresh() {
        let found: [BoostDisplay] = NSScreen.screens.compactMap { screen in
            guard let id = screen.displayID else { return nil }
            return BoostDisplay(
                id: id,
                name: screen.localizedName,
                isBuiltin: CGDisplayIsBuiltin(id) != 0,
                potentialHeadroom: screen.potentialHeadroom
            )
        }

        guard found != displays else { return }
        displays = found
        log("DisplayRegistry: \(found.map { "\($0.name)#\($0.id) potential=\(String(format: "%.2f", $0.potentialHeadroom))" }.joined(separator: ", "))")
        onChange?(found)
    }

    /// Displays that are XDR-capable and not excluded by the user.
    func eligibleDisplays() -> [BoostDisplay] {
        displays.filter { $0.supportsEDR && !Settings.shared.isExcluded($0.id) }
    }
}
