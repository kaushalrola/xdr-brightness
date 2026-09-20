import AppKit

/// A display we may boost. `NSScreen` instances are replaced wholesale on
/// reconfiguration, so we key everything by `CGDirectDisplayID` and re-resolve
/// the screen on demand rather than caching it.
struct BoostDisplay: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let name: String
    let isBuiltin: Bool
    let potentialHeadroom: Double

    /// An XDR-capable display reports potential headroom above 1.0.
    var supportsEDR: Bool { potentialHeadroom > 1.01 }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Live headroom. Rises once EDR content is actually on screen.
    var currentHeadroom: Double {
        Double(maximumExtendedDynamicRangeColorComponentValue)
    }

    var potentialHeadroom: Double {
        Double(maximumPotentialExtendedDynamicRangeColorComponentValue)
    }
}
