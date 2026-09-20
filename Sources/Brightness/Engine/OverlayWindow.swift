import AppKit

enum OverlayRole {
    /// Full-screen, multiply-composited. Actually brightens the display.
    case multiply
    /// 1x1 pixel. Holds EDR headroom open so the gamma backend has room to work.
    case trigger
}

final class OverlayWindow: NSWindow {
    private(set) var overlayView: MetalOverlayView?
    let role: OverlayRole
    private var gain: Double

    init(role: OverlayRole, gain: Double) {
        self.role = role
        self.gain = gain

        let rect = NSRect(x: 0, y: 0, width: 1, height: 1)
        super.init(
            contentRect: rect,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        // Above everything, including other apps' fullscreen spaces. Without
        // .canJoinAllApplications and .fullScreenAuxiliary the boost silently
        // disappears the moment anything goes fullscreen.
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [
            .stationary, .canJoinAllSpaces, .ignoresCycle,
            .canJoinAllApplications, .fullScreenAuxiliary,
        ]

        isOpaque = false
        hasShadow = false
        backgroundColor = .clear
        ignoresMouseEvents = true      // never steal input
        hidesOnDeactivate = false
        canHide = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func install(onFirstFrame: @escaping () -> Void) {
        let view = MetalOverlayView(
            frame: NSRect(origin: .zero, size: frame.size),
            multiply: role == .multiply,
            gain: gain
        )
        view?.onFirstFrame = onFirstFrame
        view?.autoresizingMask = [.width, .height]
        overlayView = view
        if let view { contentView = view }
    }

    func setGain(_ newGain: Double) {
        gain = newGain
        overlayView?.setGain(newGain)
    }
}

@MainActor
final class OverlayWindowController {
    private let window: OverlayWindow
    private let role: OverlayRole
    private(set) var displayID: CGDirectDisplayID

    init(displayID: CGDirectDisplayID, role: OverlayRole, gain: Double) {
        self.displayID = displayID
        self.role = role
        self.window = OverlayWindow(role: role, gain: gain)
        window.title = "Brightness overlay \(displayID)"
    }

    func open(on screen: NSScreen) {
        position(on: screen)

        // Fade in from zero so there is no flash of unmultiplied content
        // before the first frame lands.
        window.alphaValue = 0
        window.install { [weak window] in
            window?.alphaValue = 1
        }
        window.orderFrontRegardless()

        // Belt and braces: if the first frame never reports back, show anyway.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak window] in
            window?.alphaValue = 1
        }
    }

    func update(on screen: NSScreen) {
        position(on: screen)
        window.orderFrontRegardless()
    }

    private func position(on screen: NSScreen) {
        switch role {
        case .multiply:
            window.setFrame(screen.frame, display: true)
        case .trigger:
            // A single pixel tucked into the top-left corner.
            var origin = screen.frame.origin
            origin.y += screen.frame.height - 1
            window.setFrame(NSRect(origin: origin, size: CGSize(width: 1, height: 1)), display: true)
        }
    }

    func setGain(_ gain: Double) { window.setGain(gain) }

    func close() {
        window.orderOut(nil)
        window.close()
    }

    var stats: String { window.overlayView?.stats ?? "no view" }
}
