import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var settings = Settings.shared
    @ObservedObject var coordinator: BoostCoordinator
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            method.tabItem { Label("Method", systemImage: "slider.horizontal.3") }
            displays.tabItem { Label("Displays", systemImage: "display") }
        }
        .frame(width: 460, height: 400)
    }

    private var general: some View {
        Form {
            Section {
                Toggle("Enable brightness boost", isOn: $settings.isEnabled)

                VStack(alignment: .leading) {
                    Slider(value: $settings.defaultBrightness, in: 0...1) {
                        Text("Default intensity")
                    }
                    Text("\(Int((settings.defaultBrightness * 100).rounded()))% — used by displays without their own setting, and by any display you connect later. Set individual displays on the Displays tab.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Power") {
                Toggle("Turn off on battery", isOn: $settings.disableOnBattery)
                Toggle("Turn off in Low Power Mode", isOn: $settings.disableOnLowPower)
                Text("Running an XDR panel at full brightness uses noticeably more power and generates heat.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Video") {
                Toggle("Ease off while video is playing", isOn: $settings.backOffDuringVideo)

                if settings.backOffDuringVideo {
                    VStack(alignment: .leading) {
                        Slider(value: $settings.videoIntensity, in: 0...1) {
                            Text("Intensity during video")
                        }
                        Text(settings.videoIntensity == 0
                             ? "No boost while video plays."
                             : "\(Int((settings.videoIntensity * 100).rounded()))% while video plays.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text("Boosting multiplies HDR video too, pushing highlights past what the panel can show. Easing off keeps the extra headroom unlocked for the video itself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("macOS exposes no public signal for HDR specifically, so this detects video playback of any kind.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                if coordinator.videoMonitor.isPlaying {
                    Text("Playing now: \(coordinator.videoMonitor.holders.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }
                if let launchError {
                    Text(launchError).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Other apps") {
                Toggle("Warn about conflicting apps", isOn: $settings.warnOnConflicts)
                let conflicting = coordinator.conflicts.conflictingApps()
                if !conflicting.isEmpty {
                    Text("Currently running: \(conflicting.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var method: some View {
        Form {
            Section {
                Picker("Method", selection: $settings.backend) {
                    ForEach(BackendKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.inline)

                Text(settings.backend.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("How these differ") {
                VStack(alignment: .leading, spacing: 10) {
                    methodNote(
                        title: "Multiply Overlay",
                        body: "A transparent, click-through Metal layer multiplies the screen. HDR video keeps working, and nothing persists if the app quits unexpectedly."
                    )
                    methodNote(
                        title: "Gamma Table",
                        body: "Scales the display transfer table. No GPU cost, but HDR video clips to SDR maximum and it competes with Night Shift and f.lux."
                    )
                }
            }
        }
        .formStyle(.grouped)
    }

    private func methodNote(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout.weight(.semibold))
            Text(body).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var displays: some View {
        Form {
            Section {
                ForEach(coordinator.registry.displays) { display in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(display.name)
                                Text(displaySubtitle(display))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if display.supportsEDR {
                                Toggle("", isOn: Binding(
                                    get: { !settings.isExcluded(display.id) },
                                    set: { settings.setExcluded(!$0, for: display.id) }
                                ))
                                .labelsHidden()
                            } else {
                                Text("Unsupported").font(.caption).foregroundStyle(.secondary)
                            }
                        }

                        if display.supportsEDR && !settings.isExcluded(display.id) {
                            HStack(spacing: 8) {
                                Slider(
                                    value: Binding(
                                        get: { settings.brightness(for: display.id) },
                                        set: { settings.setBrightness($0, for: display.id) }
                                    ),
                                    in: 0...1
                                )
                                Text("\(Int((settings.brightness(for: display.id) * 100).rounded()))%")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 38, alignment: .trailing)

                                if settings.hasOwnBrightness(for: display.id) {
                                    Button {
                                        settings.clearBrightness(for: display.id)
                                    } label: {
                                        Image(systemName: "arrow.uturn.backward")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Follow the default intensity again")
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Section("Calibration") {
                Text("Each display's usable headroom is measured while boost is running, so no per-model table is needed. Reset this if a display was misdetected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Reset Calibration") {
                        coordinator.calibrator.reset()
                    }
                    Spacer()
                    Button("Copy Diagnostics") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(coordinator.diagnosticsReport, forType: .string)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func displaySubtitle(_ display: BoostDisplay) -> String {
        let state = coordinator.states[display.id]?.label ?? "idle"
        let headroom = coordinator.registry.screen(for: display.id)?.currentHeadroom ?? 0
        let calibrated = coordinator.calibrator.calibratedHeadroom(for: display.id)
        let maxGain = GainModel.maximumGain(calibratedHeadroom: calibrated)
        return String(
            format: "%@ · headroom %.2f · up to %.2fx · %@",
            display.isBuiltin ? "Built-in" : "External",
            headroom, maxGain, state
        )
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchError = nil
        } catch {
            launchError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
