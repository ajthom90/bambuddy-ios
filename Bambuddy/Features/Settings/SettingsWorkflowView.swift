import SwiftUI

/// Settings → Print Workflow: print defaults, queue dispatch, preheat/keep-warm, slicer and
/// auto-drying. (The slicer pipelines editor is a separate feature and not part of this page.)
struct SettingsWorkflowView: View {
    @Environment(ServerSettingsStore.self) private var store
    @Environment(PrinterStore.self) private var printerStore

    var body: some View {
        SettingsForm("Print Workflow") {
            printDefaultsSection
            queueSection
            staggerSection
            presetsSection
            preheatSection
            keepWarmSection
            slicerSection
            pipelineSection
            dryingSection
        }
        .modifier(SettingsWorkflowKeyboardDone())
        .task {
            if printerStore.printers.isEmpty, !printerStore.isLoading { await printerStore.refresh() }
        }
    }

    // MARK: Print defaults

    private var hasDualNozzlePrinter: Bool {
        printerStore.printers.contains { ($0.nozzleCount ?? 1) >= 2 }
    }

    private var printDefaultsSection: some View {
        Section {
            SettingsWorkflowCalibrationRow(title: "Bed Leveling", key: "default_bed_levelling",
                                           help: "Probe the bed before printing.")
            SettingsWorkflowCalibrationRow(title: "Flow Calibration", key: "default_flow_cali",
                                           help: "Measure and tune extrusion flow.")
            if hasDualNozzlePrinter || store.string("default_nozzle_offset_cali", default: "auto") != "auto" {
                SettingsWorkflowCalibrationRow(title: "Nozzle Offset Calibration", key: "default_nozzle_offset_cali",
                                               help: "Align the two nozzles on dual-nozzle printers.")
            }
            SettingsToggle("Vibration Calibration", key: "default_vibration_cali",
                           help: "Compensate for resonance to reduce ringing.", default: true)
            SettingsToggle("First Layer Inspection", key: "default_layer_inspect",
                           help: "Check the first layer with the printer's camera or lidar.")
            SettingsToggle("Timelapse", key: "default_timelapse", help: "Record a timelapse video.")
        } header: {
            Text("Default Print Options")
        } footer: {
            Text("Starting values for new prints. Each print can still override them. Auto lets the printer decide when calibration is needed.")
        }
    }

    // MARK: Queue

    private var queueSection: some View {
        Section {
            SettingsToggle("Require Plate-Clear Confirmation", key: "require_plate_clear",
                           help: "After a print finishes, wait for someone to confirm the plate is clear before the queue starts the next job. Turning this off also hides the plate status and \"plate cleared\" button on printer cards.")
            SettingsToggle("Shortest Job First", key: "queue_shortest_first",
                           help: "Start shorter queued prints ahead of longer ones.")
            SettingsStepper("Parallel Uploads", key: "queue_max_concurrent_uploads", range: 1...16,
                            help: "How many printers the queue sends files to at once.", default: 4)
        } header: {
            Text("Queue")
        } footer: {
            Text("File transfers to printers are slow, so on larger fleets more parallel uploads get a batch started sooner. Lower the value if your network or server struggles. 1 uploads to one printer at a time.")
        }
    }

    private var staggerSection: some View {
        Section {
            SettingsStepper("Group Size", key: "stagger_group_size", range: 1...50,
                            help: "Printers started together in each group.", default: 2)
            SettingsStepper("Interval", key: "stagger_interval_minutes", range: 1...60, unit: "min",
                            help: "Delay before the next group starts.", default: 5)
        } header: {
            Text("Staggered Start")
        } footer: {
            Text("Defaults used when a multi-printer batch is started in staggered groups. Each batch can override them.")
        }
    }

    private var presetsSection: some View {
        Section {
            NavigationLink {
                SettingsWorkflowPresetsView()
            } label: {
                LabeledContent {
                    Text(presetsSummary)
                } label: {
                    Label("Temperature & Fan Presets", systemImage: "thermometer.medium")
                }
            }
        } footer: {
            Text("Quick-pick values offered by the temperature and fan controls on printer cards.")
        }
    }

    private var presetsSummary: String {
        let customized = SettingsWorkflowPresetCategory.all.filter { !store.string($0.key).isEmpty }.count
        return customized == 0 ? "Default" : "\(customized) customized"
    }

    // MARK: Preheat

    private var preheatEnabled: Bool { store.bool("preheat_enabled") }
    private var plateClearRequired: Bool { store.bool("require_plate_clear") }

    private var preheatSection: some View {
        Section {
            SettingsToggle("Preheat & Heat Soak", key: "preheat_enabled",
                           help: "Heat the bed (and chamber where supported) and hold it before each queued print. When off, queued prints start immediately.")
            Group {
                SettingsNumberField("Maximum Wait", key: "preheat_max_wait_seconds", unit: "s",
                                    help: "Longest time to wait for the chamber to warm up (60–3600).",
                                    range: 60...3600)
                SettingsNumberField("Soak Time", key: "preheat_soak_seconds", unit: "s",
                                    help: "Extra hold once the target is reached or the wait runs out (0–1800).",
                                    range: 0...1800)
                NavigationLink {
                    SettingsPreheatTargetsView()
                } label: {
                    LabeledContent {
                        Text(store.string("preheat_filament_targets").isEmpty ? "Default" : "Customized")
                    } label: {
                        SettingsLabel("Chamber Targets by Filament", help: "Chamber temperature to reach for each material.")
                    }
                }
            }
            .disabled(!preheatEnabled)
        } header: {
            Text("Preheat")
        } footer: {
            Text("Useful for engineering filaments such as ABS, ASA or PA. The bed temperature comes from the print file. H2-series, X2D and X1E printers heat the chamber actively; X1C and P2S warm it from the bed and measure it; P1 and A1 printers have no chamber sensor, so only the soak timer applies.")
        }
    }

    private var keepWarmSection: some View {
        Section {
            SettingsToggle("Keep Bed Warm Between Prints", key: "queue_keep_bed_warm",
                           help: "While waiting for plate-clear confirmation, hold the bed hot so the chamber stays warm for the next print. Only used when the next print needs chamber heat.")
                .disabled(!preheatEnabled || !plateClearRequired)
            SettingsNumberField("Keep-Warm Bed Temperature", key: "queue_keep_warm_bed_temp", unit: "°C",
                                help: "Used whenever the bed heats the chamber. A higher bed temperature from the print file always wins (40–110).",
                                range: 40...110)
                .disabled(!preheatEnabled)
            SettingsNumberField("Stop Keeping Warm After", key: "queue_keep_warm_max_minutes", unit: "min",
                                help: "Turn the heaters off if the plate isn't cleared in time (5–480).",
                                range: 5...480)
                .disabled(!preheatEnabled || !plateClearRequired || !store.bool("queue_keep_bed_warm"))
        } header: {
            Text("Keep Warm")
        } footer: {
            if !preheatEnabled || !plateClearRequired {
                Text("Requires Preheat & Heat Soak and plate-clear confirmation to be turned on.")
            }
        }
    }

    // MARK: Slicer

    private var preferredSlicer: String { store.string("preferred_slicer", default: "bambu_studio") }

    private var slicerSection: some View {
        let isOrca = preferredSlicer == "orcaslicer"
        let urlKey = isOrca ? "orcaslicer_api_url" : "bambu_studio_api_url"
        return Section {
            SettingsPicker("Slicer", key: "preferred_slicer",
                           choices: [("bambu_studio", "Bambu Studio"), ("orcaslicer", "OrcaSlicer")],
                           help: "Slicer driven by the server-side slicing service.")
            if isOrca {
                Label("Current OrcaSlicer command-line builds fail on many Bambu-authored 3MF files. Bambu Studio is recommended for now.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            SettingsWorkflowOpenInSlicerPicker()
            SettingsToggle("Use Slicing Service", key: "use_slicer_api",
                           help: "Slice inside Bambuddy with the slicer service container. When off, slicing hands the file to your desktop slicer.")
            if store.bool("use_slicer_api") {
                SettingsTextField(isOrca ? "OrcaSlicer Service URL" : "Bambu Studio Service URL", key: urlKey,
                                  prompt: isOrca ? "http://localhost:3003" : "http://localhost:3001",
                                  help: "Leave empty to use the server's environment defaults.",
                                  keyboard: .URL)
                    .id(urlKey)
                SettingsNumberField("Stall Timeout", key: "slicer_stall_timeout_minutes", unit: "min",
                                    help: "Give up on a slice after this long without progress from the service (1–240).",
                                    range: 1...240)
            }
        } header: {
            Text("Slicer")
        }
    }

    private var pipelineSection: some View {
        Section {
            SettingsNumberField("Maximum Copies per Run", key: "pipeline_max_copies",
                                help: "Upper limit on copies requested when running a slicer pipeline (1–1000).",
                                range: 1...1000)
        } header: {
            Text("Slicer Pipelines")
        } footer: {
            Text("Pipelines themselves are managed in the Bambuddy web interface.")
        }
    }

    // MARK: Drying

    private var dryingSection: some View {
        Section {
            SettingsToggle("Auto-Dry Between Queued Prints", key: "queue_drying_enabled",
                           help: "Start AMS drying on idle printers when humidity is above the trigger level.")
            if store.bool("queue_drying_enabled") {
                SettingsToggle("Wait for Drying to Finish", key: "queue_drying_block",
                               help: "Hold the queue until drying completes. When off, prints take priority.")
            }
            SettingsToggle("Ambient Drying", key: "ambient_drying_enabled",
                           help: "Also dry filament on idle printers when nothing is queued.")
            SettingsToggle("Keep Drying While Printing", key: "print_drying_enabled",
                           help: "On supported printers and firmware, keep drying during a print at a slightly lower temperature to protect the spools.")
            NavigationLink {
                SettingsDryingPresetsView()
            } label: {
                LabeledContent {
                    Text(store.string("drying_presets").isEmpty ? "Default" : "Customized")
                } label: {
                    Label("Drying Presets", systemImage: "flame")
                }
            }
            NavigationLink {
                SettingsDryingHumidityView()
            } label: {
                LabeledContent {
                    Text(SettingsDryingHumidity.parse(store.string("ams_humidity_thresholds")).isEmpty ? "Default" : "Customized")
                } label: {
                    Label("Humidity Triggers", systemImage: "humidity")
                }
            }
        } header: {
            Text("Auto-Drying")
        } footer: {
            Text("Drying is triggered by the per-filament humidity levels, which default to the AMS \"fair\" humidity threshold on the Filament & AMS page.")
        }
    }
}

/// Off / Auto / On selector for a tri-state calibration default.
private struct SettingsWorkflowCalibrationRow: View {
    @Environment(ServerSettingsStore.self) private var store
    let title: String
    let key: String
    var help: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsLabel(title, help: help)
            Picker(title, selection: store.stringBinding(key, default: "auto")) {
                Text("Off").tag("off")
                Text("Auto").tag("auto")
                Text("On").tag("on")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.vertical, 2)
        .disabled(!store.canEdit)
    }
}

/// Desktop slicer for "Open in Slicer"; empty means "same as the slicer above" (sent as null).
private struct SettingsWorkflowOpenInSlicerPicker: View {
    @Environment(ServerSettingsStore.self) private var store
    private let key = "open_in_slicer"

    var body: some View {
        let current = store.string(key)
        Picker(selection: Binding(
            get: { current },
            set: { newValue in
                Task { await store.save([key: newValue.isEmpty ? .null : .string(newValue)]) }
            }
        )) {
            Text("Same as Slicer").tag("")
            Text("Bambu Studio").tag("bambu_studio")
            Text("OrcaSlicer").tag("orcaslicer")
            if !["", "bambu_studio", "orcaslicer"].contains(current) {
                Text(current).tag(current)
            }
        } label: {
            SettingsLabel("Open in Slicer", help: "Desktop app used by the Open in Slicer action.")
        }
        .disabled(!store.canEdit)
    }
}
