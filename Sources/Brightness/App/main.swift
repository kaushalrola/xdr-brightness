import AppKit

// Top-level code is not implicitly main-actor isolated in Swift 5 language
// mode, but it does run on the main thread.
MainActor.assumeIsolated {
    let app = NSApplication.shared

    // Headless probe: `Brightness --diagnose` reports what the displays
    // advertise without starting the UI. Useful for calibrating the gain model.
    if CommandLine.arguments.contains("--diagnose") {
        app.setActivationPolicy(.prohibited)
        print("=== Display probe ===")
        for screen in NSScreen.screens {
            let id = screen.displayID ?? 0
            let builtin = CGDisplayIsBuiltin(id) != 0
            print(String(
                format: "%@ #%u\n  builtin:   %@\n  potential: %.4f\n  current:   %.4f\n  reference: %.4f\n  XDR:       %@",
                screen.localizedName, id,
                builtin ? "yes" : "no",
                screen.potentialHeadroom,
                screen.currentHeadroom,
                Double(screen.maximumReferenceExtendedDynamicRangeColorComponentValue),
                screen.potentialHeadroom > 1.01 ? "yes" : "no"
            ))

            if screen.potentialHeadroom > 1.01 {
                let calibrator = HeadroomCalibrator()
                let calibrated = calibrator.calibratedHeadroom(for: id)
                let known = calibrator.hasObservation(for: id)
                print(String(
                    format: "  learned:   %.4f%@\n  max gain:  %.3fx",
                    calibrated, known ? "" : " (default, not yet observed)",
                    GainModel.maximumGain(calibratedHeadroom: calibrated)
                ))
            }
            if screen.potentialHeadroom > 1.01 {
                // Resolve intensity and gain through the same Settings and
                // GainModel paths the running app uses.
                let intensity = Settings.shared.brightness(for: id)
                let own = Settings.shared.hasOwnBrightness(for: id)
                let calibrated = HeadroomCalibrator().calibratedHeadroom(for: id)
                let wouldApply = GainModel.gain(
                    currentHeadroom: max(calibrated, screen.currentHeadroom),
                    calibratedHeadroom: calibrated,
                    userBrightness: intensity
                )
                print(String(
                    format: "  intensity: %.2f (%@)\n  would use: %.3fx",
                    intensity, own ? "own setting" : "default", wouldApply
                ))
            }

            if let table = GammaTable.capture(displayID: id) {
                let end = table.endpoint
                print(String(format: "  gamma top: %.4f, %.4f, %.4f%@",
                             end.0, end.1, end.2,
                             end.0 > 1.001 ? "  <- boosted" : ""))
            }
            print("")
        }
        print("=== Power ===")
        let power = PowerPolicy()
        power.start()
        print("  on battery:  \(power.isOnBattery)")
        print("  low power:   \(power.isLowPower)")
        print("  suppressed:  \(power.shouldSuppressBoost)\(power.suppressionReason.map { " — \($0)" } ?? "")")
        print("")

        print("=== Playback detection ===")
        print("  all display-wake assertions: \(VideoPlaybackMonitor.allDisplayAwakeHolders())")
        print("  counted as playback:         \(VideoPlaybackMonitor.playbackHolders())")
        print("  all assertions:")
        for line in VideoPlaybackMonitor.assertionDetail() { print("    \(line)") }
        exit(0)
    }

    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
