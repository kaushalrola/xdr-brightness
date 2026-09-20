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
                    Slider(value: $settings.brightness, in: 0...1) {
                        Text("Intensity")
                    }
                    Text("\(Int((settings.brightness * 100).rounded()))% of the headroom your display reports")
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
