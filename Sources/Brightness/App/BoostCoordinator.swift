import AppKit
import Combine

/// Per-display engagement state.
///
/// The visual effect is ten lines of Metal. This state machine is the actual
/// product: HDR engage timeouts, cooldown/retry, and per-display isolation so
/// one uncooperative external monitor never disables a working built-in panel.
enum EngagementState: Equatable {
    case idle
    case engaging(since: Date)
    case ready
    case cooldown(until: Date)
    case isolated

    var label: String {
        switch self {
        case .idle:      return "idle"
        case .engaging:  return "engaging"
        case .ready:     return "ready"
        case .cooldown:  return "cooldown"
        case .isolated:  return "isolated"
        }
    }
}

@MainActor
final class BoostCoordinator: ObservableObject {

    // Tuning
    private let engageTimeout: TimeInterval = 25
    private let cooldownDuration: TimeInterval = 30
    private let maxConsecutiveFailures = 3
    private let restInterval: Duration = .milliseconds(500)
    private let burstInterval: Duration = .milliseconds(16)
    private let burstDuration: TimeInterval = 30

    // Collaborators
    let registry = DisplayRegistry()
    let calibrator = HeadroomCalibrator()
    let power = PowerPolicy()
    let conflicts = ConflictMonitor()
    private var overlayBackend: OverlayBackend!
    private var gammaBackend: GammaBackend!

    // State
    @Published private(set) var states: [CGDirectDisplayID: EngagementState] = [:]
    @Published private(set) var statusText: String = "Off"
    @Published private(set) var isBoosting = false

    private var failureCounts: [CGDirectDisplayID: Int] = [:]
    private var burstUntil: Date?
    private var tickTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var isAsleep = false

    var onConflictsDetected: (([String]) -> Void)?

    private var activeBackend: BrightnessBackend {
        Settings.shared.backend == .overlay ? overlayBackend : gammaBackend
    }

    private var inactiveBackend: BrightnessBackend {
        Settings.shared.backend == .overlay ? gammaBackend : overlayBackend
    }

    // MARK: - Lifecycle

    func start() {
        overlayBackend = OverlayBackend(registry: registry)
        gammaBackend = GammaBackend(registry: registry)

        registry.onChange = { [weak self] displays in
            self?.handleTopologyChange(displays)
        }
        registry.start()

        power.onChange = { [weak self] in self?.reevaluate() }
        power.start()

        observeSleepWake()

        Settings.shared.didChange
            .sink { [weak self] in self?.reevaluate() }
            .store(in: &cancellables)

        startTicking()
        reevaluate()
        log("BoostCoordinator: started")
    }

    func shutdown() {
        tickTask?.cancel()
        tickTask = nil
        overlayBackend?.deactivate()
        gammaBackend?.deactivate()
        SafetyNet.restoreNow()
        log("BoostCoordinator: shut down")
    }

    private func observeSleepWake() {
        let nc = NSWorkspace.shared.notificationCenter

        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isAsleep = true
                log("BoostCoordinator: system sleeping — deactivating")
                // Gamma must be restored before sleep or it can persist oddly.
                self.overlayBackend.deactivate()
                self.gammaBackend.deactivate()
                self.resetAllStates()
                self.refreshStatus()
            }
        }

        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isAsleep = false
                log("BoostCoordinator: system woke — re-engaging")
                self.resetAllStates()
                self.beginBurst()
                self.reevaluate()
            }
        }

        nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.beginBurst() }
        }
    }

    // MARK: - Top-level decisions

    /// Should boost be running at all right now?
    private var shouldBoost: Bool {
        guard Settings.shared.isEnabled else { return false }
        guard !isAsleep else { return false }
        guard !power.shouldSuppressBoost else { return false }
        return !registry.eligibleDisplays().isEmpty
    }

    func reevaluate() {
        // A backend switch must fully tear down the old one first, or the
        // display is left holding two lots of state.
        if inactiveBackend.isActive {
            log("BoostCoordinator: backend switched — tearing down \(inactiveBackend.kind.rawValue)")
            inactiveBackend.deactivate()
            resetAllStates()
        }

        let displays = registry.eligibleDisplays()

        if shouldBoost {
            if !activeBackend.isActive {
                log("BoostCoordinator: activating \(activeBackend.kind.rawValue) on \(displays.count) display(s)")
                activeBackend.activate(on: displays)
                beginBurst()
                for display in displays where states[display.id] == nil {
                    states[display.id] = .engaging(since: Date())
                }
            } else {
                activeBackend.displaysChanged(displays)
            }

            let fresh = conflicts.newConflicts()
            if !fresh.isEmpty {
                log("BoostCoordinator: conflicting apps detected: \(fresh.joined(separator: ", "))")
                onConflictsDetected?(fresh)
            }
        } else if activeBackend.isActive {
            log("BoostCoordinator: deactivating — conditions no longer met")
            activeBackend.deactivate()
            resetAllStates()
        }

        refreshStatus()
    }

    private func handleTopologyChange(_ displays: [BoostDisplay]) {
        log("BoostCoordinator: topology changed (\(displays.count) display(s))")
        let known = Set(displays.map(\.id))
        for id in states.keys where !known.contains(id) {
            states.removeValue(forKey: id)
            failureCounts.removeValue(forKey: id)
        }
        beginBurst()
        reevaluate()
    }

    private func resetAllStates() {
        states.removeAll()
        failureCounts.removeAll()
    }

    // MARK: - Polling

    private func beginBurst() {
        burstUntil = Date().addingTimeInterval(burstDuration)
    }

    private var currentInterval: Duration {
        if let burstUntil, Date() < burstUntil { return burstInterval }
        return restInterval
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.tick()
                try? await Task.sleep(for: self.currentInterval)
            }
        }
    }

    private func tick() {
        power.refreshBattery()

        guard activeBackend.isActive else { return }
        activeBackend.poll()

        for display in registry.eligibleDisplays() {
            guard let screen = registry.screen(for: display.id) else { continue }
            let userBrightness = Settings.shared.brightness(for: display.id)
            let headroom = screen.currentHeadroom
            let state = states[display.id] ?? .engaging(since: Date())

            switch state {
            case .idle:
                states[display.id] = .engaging(since: Date())

            case .engaging(let since):
                if headroom > GainModel.readyThreshold {
                    log(String(format: "BoostCoordinator: display %u engaged (headroom %.3f)", display.id, headroom))
                    states[display.id] = .ready
                    failureCounts[display.id] = 0
                    applyGain(display: display, headroom: headroom, userBrightness: userBrightness)
                } else if Date().timeIntervalSince(since) >= engageTimeout {
                    enterCooldown(display)
                }

            case .ready:
                if headroom <= GainModel.readyThreshold {
                    log(String(format: "BoostCoordinator: display %u lost headroom (%.3f)", display.id, headroom))
                    activeBackend.setGain(1.0, for: display.id)
                    states[display.id] = .engaging(since: Date())
                    beginBurst()
                } else {
                    applyGain(display: display, headroom: headroom, userBrightness: userBrightness)
                }

            case .cooldown(let until):
                if Date() >= until {
                    log("BoostCoordinator: display \(display.id) cooldown ended, retrying")
                    states[display.id] = .engaging(since: Date())
                    beginBurst()
                }

            case .isolated:
                // Keep watching: an isolated display recovers on its own if the
                // system later grants headroom.
                if headroom > GainModel.readyThreshold {
                    log("BoostCoordinator: isolated display \(display.id) recovered")
                    states[display.id] = .ready
                    failureCounts[display.id] = 0
                    applyGain(display: display, headroom: headroom, userBrightness: userBrightness)
                }
            }
        }

        refreshStatus()
    }

    private func applyGain(display: BoostDisplay, headroom: Double, userBrightness: Double) {
        // Every ready tick teaches us a little more about this panel.
        calibrator.record(headroom, for: display.id)

        let gain = GainModel.gain(
            currentHeadroom: headroom,
            calibratedHeadroom: calibrator.calibratedHeadroom(for: display.id),
            userBrightness: userBrightness
        )
        activeBackend.setGain(gain, for: display.id)
    }

    private func enterCooldown(_ display: BoostDisplay) {
        let count = (failureCounts[display.id] ?? 0) + 1
        failureCounts[display.id] = count

        activeBackend.setGain(1.0, for: display.id)

        if count >= maxConsecutiveFailures {
            states[display.id] = .isolated
            log("BoostCoordinator: display \(display.id) isolated after \(count) failed engage attempts — other displays unaffected")
        } else {
            states[display.id] = .cooldown(until: Date().addingTimeInterval(cooldownDuration))
            log("BoostCoordinator: display \(display.id) failed to engage (\(count)/\(maxConsecutiveFailures)), cooling down")
        }
    }

    // MARK: - Status

    private func readyDisplayIDs() -> [CGDirectDisplayID] {
        states.compactMap { $0.value == .ready ? $0.key : nil }
    }

    private func refreshStatus() {
        let wasBoosting = isBoosting
        let readyCount = states.values.filter { $0 == .ready }.count
        isBoosting = activeBackend.isActive && readyCount > 0

        let text: String
        if !Settings.shared.isEnabled {
            text = "Off"
        } else if let reason = power.suppressionReason {
            text = reason
        } else if isAsleep {
            text = "Asleep"
        } else if registry.eligibleDisplays().isEmpty {
            text = "No XDR display"
        } else if readyCount > 0 {
            let values = readyDisplayIDs().map { Settings.shared.brightness(for: $0) }
            let percentages = Set(values.map { Int(($0 * 100).rounded()) })

            if let only = percentages.count == 1 ? percentages.first : nil {
                text = readyCount > 1
                    ? "Boosting \(readyCount) displays — \(only)%"
                    : "Boosting — \(only)%"
            } else {
                // Displays are set to different intensities; a single number
                // would be a lie, so show the range instead.
                let low = percentages.min() ?? 0
                let high = percentages.max() ?? 0
                text = "Boosting \(readyCount) displays — \(low)–\(high)%"
            }
        } else if states.values.contains(where: { if case .cooldown = $0 { return true } else { return false } }) {
            text = "Waiting to retry"
        } else if states.values.contains(.isolated) {
            text = "HDR unavailable"
        } else {
            text = "Engaging…"
        }

        if text != statusText || wasBoosting != isBoosting {
            statusText = text
        }
    }

    // MARK: - Actions

    func toggle() {
        Settings.shared.isEnabled.toggle()
        log("BoostCoordinator: toggled \(Settings.shared.isEnabled ? "on" : "off") by user")
    }

    func nudgeBrightness(by delta: Double) {
        let settings = Settings.shared
        if !settings.isEnabled && delta > 0 { settings.isEnabled = true }
        settings.nudgeBrightness(by: delta, for: registry.eligibleDisplays().map(\.id))
    }

    var diagnosticsReport: String {
        var out = "=== Brightness diagnostics ===\n"
        out += "Backend: \(Settings.shared.backend.rawValue)\n"
        out += "Enabled: \(Settings.shared.isEnabled)  Default intensity: \(String(format: "%.2f", Settings.shared.defaultBrightness))\n"
        out += "On battery: \(power.isOnBattery)  Low power: \(power.isLowPower)\n"
        out += "Conflicting apps: \(conflicts.conflictingApps().joined(separator: ", "))\n\n"

        out += "Displays:\n"
        for display in registry.displays {
            let screen = registry.screen(for: display.id)
            let headroom = screen?.currentHeadroom ?? 0
            let state = states[display.id]?.label ?? "-"
            let calibrated = calibrator.calibratedHeadroom(for: display.id)
            out += String(
                format: "  %@ #%u builtin=%@ potential=%.2f current=%.3f calibrated=%.3f%@ maxGain=%.3fx intensity=%.2f%@ state=%@\n",
                display.name, display.id, display.isBuiltin ? "yes" : "no",
                display.potentialHeadroom, headroom, calibrated,
                calibrator.hasObservation(for: display.id) ? "" : " (default)",
                GainModel.maximumGain(calibratedHeadroom: calibrated),
                Settings.shared.brightness(for: display.id),
                Settings.shared.hasOwnBrightness(for: display.id) ? "" : " (default)",
                state
            )
        }

        if let overlay = overlayBackend, overlay.isActive {
            out += "\nOverlay windows:\n" + overlay.diagnostics + "\n"
        }

        out += "\nLog:\n" + Diagnostics.shared.report
        return out
    }
}
