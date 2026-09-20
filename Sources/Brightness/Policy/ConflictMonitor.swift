import AppKit

/// Other apps that write the same display state. We warn once and get out of
/// the way rather than fighting them.
@MainActor
final class ConflictMonitor {
    private static let known: [String: String] = [
        "org.herf.Flux": "f.lux",
        "pro.betterdisplay.BetterDisplay": "BetterDisplay",
        "me.guillaumeb.MonitorControl": "MonitorControl",
        "com.brightintosh.BrightIntosh": "BrightIntosh",
        "de.brightintosh.BrightIntosh": "BrightIntosh",
        "com.lunar.Lunar": "Lunar",
        "fyi.lunar.Lunar": "Lunar",
    ]

    private var alreadyWarned: Set<String> = []

    func conflictingApps() -> [String] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let id = app.bundleIdentifier else { return nil }
            return Self.known[id]
        }
        .uniqued()
    }

    /// Returns names not yet warned about, and marks them warned.
    func newConflicts() -> [String] {
        guard Settings.shared.warnOnConflicts else { return [] }
        let current = conflictingApps()
        let fresh = current.filter { !alreadyWarned.contains($0) }
        alreadyWarned.formUnion(fresh)
        return fresh
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
