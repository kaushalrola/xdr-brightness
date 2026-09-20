import AppKit
import IOKit.pwr_mgt

/// Detects video playback so boost can ease off and stop clipping highlights.
///
/// ## Why this is playback detection and not HDR detection
///
/// macOS exposes no public, per-process signal for "HDR content is on screen".
/// Reported EDR headroom saturates to the panel maximum as soon as *any* EDR
/// content exists — including our own overlay — so there is no differential
/// left to read once boost is running.
///
/// What is publicly observable is the display-sleep power assertion that video
/// players hold while playing, via `IOPMCopyAssertionsByProcess`. That catches
/// HDR video, but it catches SDR video too, which is why the behaviour is a
/// setting rather than something forced on everyone.
@MainActor
final class VideoPlaybackMonitor {

    private(set) var isPlaying = false
    private(set) var holders: [String] = []

    var onChange: (() -> Void)?

    /// Assertion types that mean "keep the display awake, something is on it".
    private static let displayAwakeTypes: Set<String> = [
        kIOPMAssertionTypePreventUserIdleDisplaySleep as String,
        "NoDisplaySleepAssertion",
    ]

    /// Processes that hold these assertions for reasons unrelated to playback.
    /// Backing off for these would be wrong.
    private static let ignoredProcesses: Set<String> = [
        // Hold display assertions for reasons unrelated to playback.
        "WindowServer", "powerd", "loginwindow", "coreaudiod", "Brightness",
        // Deliberate keep-awake tools; the user already chose to stay awake.
        "caffeinate", "Amphetamine", "KeepingYouAwake",
    ]

    /// `IOPMCopyAssertionsByProcess` allocates, so this is throttled.
    private var lastCheck = Date.distantPast
    private let interval: TimeInterval = 2

    func refresh(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastCheck) >= interval else { return }
        lastCheck = Date()

        let found = Self.playbackHolders()
        let playing = !found.isEmpty

        guard playing != isPlaying || found != holders else { return }

        let wasPlaying = isPlaying
        isPlaying = playing
        holders = found

        if playing != wasPlaying {
            log(playing
                ? "VideoPlaybackMonitor: playback started (\(found.joined(separator: ", ")))"
                : "VideoPlaybackMonitor: playback stopped")
            onChange?()
        }
    }

    /// Every process asserting display-wake, before filtering. Diagnostics only.
    static func allDisplayAwakeHolders() -> [String] {
        holders(filtered: false)
    }

    /// Every display-related assertion with its type, for diagnosing
    /// false positives. Diagnostics only.
    static func assertionDetail() -> [String] {
        var handle: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&handle) == kIOReturnSuccess,
              let byProcess = handle?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else { return [] }

        var lines: Set<String> = []
        for (_, assertions) in byProcess {
            for assertion in assertions {
                let type = (assertion["AssertionTrueType"] as? String)
                    ?? (assertion["AssertionType"] as? String) ?? "?"
                let name = (assertion["Process Name"] as? String) ?? "unknown"
                lines.insert("\(name) [\(type)]")
            }
        }
        return lines.sorted()
    }

    /// Names of processes currently asserting that the display stay awake,
    /// excluding ourselves and known non-playback holders.
    static func playbackHolders() -> [String] {
        holders(filtered: true)
    }

    private static func holders(filtered: Bool) -> [String] {
        var handle: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&handle) == kIOReturnSuccess,
              let byProcess = handle?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else { return [] }

        let selfName = ProcessInfo.processInfo.processName
        var names: Set<String> = []

        for (_, assertions) in byProcess {
            for assertion in assertions {
                let type = (assertion["AssertionTrueType"] as? String)
                    ?? (assertion["AssertionType"] as? String)
                guard let type, Self.displayAwakeTypes.contains(type) else { continue }

                let name = (assertion["Process Name"] as? String) ?? "unknown"
                if filtered {
                    guard name != selfName, !Self.ignoredProcesses.contains(name) else { continue }
                }
                names.insert(name)
            }
        }
        return names.sorted()
    }

    var diagnostics: String {
        isPlaying ? "playing (\(holders.joined(separator: ", ")))" : "idle"
    }
}
