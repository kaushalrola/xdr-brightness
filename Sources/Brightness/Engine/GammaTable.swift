import CoreGraphics

/// Captures the display's existing transfer table and scales it.
///
/// Scaling the captured table (rather than synthesising a fresh ramp) preserves
/// the user's colour profile and calibration.
struct GammaTable {
    static let size: UInt32 = 256

    private(set) var red: [CGGammaValue]
    private(set) var green: [CGGammaValue]
    private(set) var blue: [CGGammaValue]

    static func capture(displayID: CGDirectDisplayID) -> GammaTable? {
        var red = [CGGammaValue](repeating: 0, count: Int(size))
        var green = [CGGammaValue](repeating: 0, count: Int(size))
        var blue = [CGGammaValue](repeating: 0, count: Int(size))
        var count: UInt32 = 0

        let result = CGGetDisplayTransferByTable(displayID, size, &red, &green, &blue, &count)
        guard result == .success, count == size else {
            log("GammaTable: capture failed for display \(displayID), error \(result.rawValue)")
            return nil
        }
        return GammaTable(red: red, green: green, blue: blue)
    }

    @discardableResult
    func apply(to displayID: CGDirectDisplayID, gain: Double) -> Bool {
        let factor = CGGammaValue(gain)
        var r = red.map { $0 * factor }
        var g = green.map { $0 * factor }
        var b = blue.map { $0 * factor }

        let result = CGSetDisplayTransferByTable(displayID, Self.size, &r, &g, &b)
        if result != .success {
            log("GammaTable: apply failed for display \(displayID), error \(result.rawValue)")
            return false
        }
        return true
    }

    /// Top-of-ramp values, used by the drift watchdog.
    var endpoint: (Double, Double, Double) {
        (Double(red.last ?? 0), Double(green.last ?? 0), Double(blue.last ?? 0))
    }
}
