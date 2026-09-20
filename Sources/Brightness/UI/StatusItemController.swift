import AppKit
import Combine

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let coordinator: BoostCoordinator
    private var cancellables = Set<AnyCancellable>()

    var onOpenSettings: (() -> Void)?
    var onOpenOnboarding: (() -> Void)?

    init(coordinator: BoostCoordinator) {
        self.coordinator = coordinator
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        coordinator.$statusText
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshIcon() }
            .store(in: &cancellables)

        coordinator.$isBoosting
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshIcon() }
            .store(in: &cancellables)

        refreshIcon()
    }

    private func refreshIcon() {
        guard let button = statusItem.button else { return }

        let enabled = Settings.shared.isEnabled
        let name = coordinator.isBoosting
            ? "sun.max.fill"
            : (enabled ? "sun.max" : "sun.min")

        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Brightness")
        image?.isTemplate = true
        button.image = image
        button.toolTip = "Brightness — \(coordinator.statusText)"
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let settings = Settings.shared

        let status = NSMenuItem(title: coordinator.statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let toggle = NSMenuItem(
            title: settings.isEnabled ? "Turn Off" : "Turn On",
            action: #selector(toggleBoost), keyEquivalent: "b"
        )
        toggle.target = self
        menu.addItem(toggle)

        // One slider per boostable display, or a single unlabelled one when
        // there is only the built-in panel.
        let boostable = coordinator.registry.eligibleDisplays()
        if boostable.isEmpty {
            let item = NSMenuItem()
            let view = SliderMenuItemView(title: "Intensity", initial: settings.defaultBrightness) { newValue in
                MainActor.assumeIsolated { Settings.shared.defaultBrightness = newValue }
            }
            item.view = view
            menu.addItem(item)
        } else {
            for display in boostable {
                let id = display.id
                let title = boostable.count == 1 ? "Intensity" : display.name
                let item = NSMenuItem()
                let view = SliderMenuItemView(title: title, initial: settings.brightness(for: id)) { newValue in
                    MainActor.assumeIsolated { Settings.shared.setBrightness(newValue, for: id) }
                }
                item.view = view
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        // Backend picker
        let backendItem = NSMenuItem(title: "Method", action: nil, keyEquivalent: "")
        let backendMenu = NSMenu()
        for kind in BackendKind.allCases {
            let item = NSMenuItem(title: kind.title, action: #selector(selectBackend(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            item.state = settings.backend == kind ? .on : .off
            item.toolTip = kind.detail
            backendMenu.addItem(item)
        }
        backendItem.submenu = backendMenu
        menu.addItem(backendItem)

        // Per-display toggles
        let displays = coordinator.registry.displays
        if displays.count > 1 || displays.contains(where: { !$0.supportsEDR }) {
            let displaysItem = NSMenuItem(title: "Displays", action: nil, keyEquivalent: "")
            let displaysMenu = NSMenu()
            for display in displays {
                let state = coordinator.states[display.id]?.label
                let suffix = display.supportsEDR ? (state.map { " — \($0)" } ?? "") : " — not XDR"
                let item = NSMenuItem(
                    title: display.name + suffix,
                    action: display.supportsEDR ? #selector(toggleDisplay(_:)) : nil,
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = NSNumber(value: display.id)
                item.state = (display.supportsEDR && !settings.isExcluded(display.id)) ? .on : .off
                item.isEnabled = display.supportsEDR
                displaysMenu.addItem(item)
            }
            displaysItem.submenu = displaysMenu
            menu.addItem(displaysItem)
        }

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let diagnostics = NSMenuItem(title: "Copy Diagnostics", action: #selector(copyDiagnostics), keyEquivalent: "")
        diagnostics.target = self
        menu.addItem(diagnostics)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Brightness", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func toggleBoost() { coordinator.toggle() }

    @objc private func selectBackend(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let kind = BackendKind(rawValue: raw) else { return }
        Settings.shared.backend = kind
    }

    @objc private func toggleDisplay(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        let id = number.uint32Value
        Settings.shared.setExcluded(!Settings.shared.isExcluded(id), for: id)
    }

    @objc private func openSettings() { onOpenSettings?() }

    @objc private func copyDiagnostics() {
        let text = coordinator.diagnosticsReport
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        log("Diagnostics copied to clipboard")
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
