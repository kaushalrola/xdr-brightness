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
            if let table = GammaTable.capture(displayID: id) {
                let end = table.endpoint
                print(String(format: "  gamma top: %.4f, %.4f, %.4f%@",
                             end.0, end.1, end.2,
                             end.0 > 1.001 ? "  <- boosted" : ""))
            }
            print("")
        }
        exit(0)
    }

    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
