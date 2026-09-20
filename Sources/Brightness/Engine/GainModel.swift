import Foundation

enum GainModel {
    /// Headroom above this means EDR has actually engaged.
    static let readyThreshold: Double = 1.05

    /// Absolute ceiling. A bug must never be able to drive gain past this.
    static let hardCeiling: Double = 2.0

    /// Reported headroom is measured against the panel's *peak* brightness,
    /// which XDR displays only hold over small areas. Full-field they sustain
    /// roughly 1000 of 1600 nits, so only this fraction of the headroom is
    /// safely usable across the whole screen.
    ///
    /// This is what makes the model panel-independent: a 500-nit-SDR display
    /// (headroom 3.2) and a 600-nit one (headroom 2.67) both land near
    /// 960 sustained nits.
    static let sustainableFraction: Double = 0.60

    /// Used until a display has been observed. Deliberately timid.
    static let fallbackHeadroom: Double = 2.0

    static func maximumGain(calibratedHeadroom: Double) -> Double {
        min(max(calibratedHeadroom * sustainableFraction, 1.0), hardCeiling)
    }

    /// Maps the user's 0...1 intensity onto 1.0...maximumGain, then clamps to
    /// the headroom the display is granting *right now* — asking for more than
    /// that would simply clip.
    static func gain(currentHeadroom: Double, calibratedHeadroom: Double, userBrightness: Double) -> Double {
        let ceiling = maximumGain(calibratedHeadroom: calibratedHeadroom)
        let requested = 1 + (ceiling - 1) * min(max(userBrightness, 0), 1)
        return min(max(requested, 1.0), max(currentHeadroom, 1.0))
    }
}
