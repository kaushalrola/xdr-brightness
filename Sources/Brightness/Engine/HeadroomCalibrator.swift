import AppKit

/// Learns each display's real EDR headroom instead of relying on a hardcoded
/// table of device models.
///
/// Reported headroom is `peakNits / sdrWhiteNits`. It differs per panel — a
/// 500-nit-SDR XDR display settles around 3.2, a 600-nit one around 2.67 —
/// and it only reveals itself once EDR has actually engaged. So we observe it
/// at runtime, keep the running maximum, and persist it.
@MainActor
final class HeadroomCalibrator {
    private static let key = "calibratedHeadroom"

    /// Ignore absurd transient readings (some displays briefly advertise their
    /// theoretical maximum rather than the engaged value).
    private static let plausibleRange: ClosedRange<Double> = 1.0...4.0

    private var observed: [String: Double]

    init() {
        observed = (UserDefaults.standard.dictionary(forKey: Self.key) as? [String: Double]) ?? [:]
    }

    func record(_ headroom: Double, for id: CGDirectDisplayID) {
        guard Self.plausibleRange.contains(headroom) else { return }
        let key = String(id)
        let previous = observed[key] ?? 0
        guard headroom > previous + 0.001 else { return }

        observed[key] = headroom
        UserDefaults.standard.set(observed, forKey: Self.key)
        log(String(format: "Calibrator: display %u headroom now %.4f (was %.4f)", id, headroom, previous))
    }

    /// Best known headroom, or a conservative fallback before first observation.
    func calibratedHeadroom(for id: CGDirectDisplayID) -> Double {
        observed[String(id)] ?? GainModel.fallbackHeadroom
    }

    func hasObservation(for id: CGDirectDisplayID) -> Bool {
        observed[String(id)] != nil
    }

    func reset() {
        observed.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.key)
        log("Calibrator: reset all observations")
    }
}
