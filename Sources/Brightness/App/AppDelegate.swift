import AppKit
import SwiftUI
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let coordinator = BoostCoordinator()
    private var statusController: StatusItemController?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Clear anything a previous crash may have stranded, before we touch
        // the display ourselves.
        SafetyNet.restoreStrandedState()
        SafetyNet.install()

        coordinator.onConflictsDetected = { [weak self] names in
            self?.warnAboutConflicts(names)
        }
        coordinator.start()

        let controller = StatusItemController(coordinator: coordinator)
        controller.onOpenSettings = { [weak self] in self?.showSettings() }
        statusController = controller

        registerHotKeys()

        if !Settings.shared.hasCompletedOnboarding {
            showOnboarding()
        }

        log("App: launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.shutdown()
        log("App: terminating")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - Hotkeys

    private func registerHotKeys() {
        let mods = cmdKey | optionKey

        HotKeyCenter.shared.register(keyCode: kVK_ANSI_B, modifiers: mods) { [weak self] in
            self?.coordinator.toggle()
        }
        HotKeyCenter.shared.register(keyCode: kVK_UpArrow, modifiers: mods) { [weak self] in
            self?.coordinator.nudgeBrightness(by: 0.1)
        }
        HotKeyCenter.shared.register(keyCode: kVK_DownArrow, modifiers: mods) { [weak self] in
            self?.coordinator.nudgeBrightness(by: -0.1)
        }
    }

    // MARK: - Windows

    private func showSettings() {
        if let settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }

        let view = SettingsView(coordinator: coordinator)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Brightness Settings"
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func showOnboarding() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 430),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome"
        window.isReleasedWhenClosed = false
        window.center()

        let view = OnboardingView { [weak self] in
            Settings.shared.hasCompletedOnboarding = true
            Settings.shared.isEnabled = true
            self?.onboardingWindow?.close()
            self?.onboardingWindow = nil
        }
        window.contentView = NSHostingView(rootView: view)
        onboardingWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func warnAboutConflicts(_ names: [String]) {
        guard !names.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Another display app is running"
        alert.informativeText = """
        \(names.joined(separator: ", ")) also adjusts display output. \
        Running both at once can cause flickering or one app undoing the other.

        This is a warning only — nothing has been changed.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Don't Warn Again")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            Settings.shared.warnOnConflicts = false
        }
    }
}
