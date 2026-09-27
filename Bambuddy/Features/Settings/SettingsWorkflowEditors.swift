import SwiftUI

// Sub-pages of Print Workflow that edit settings stored as JSON strings.

// MARK: - Quick presets

/// Edits the three quick-pick values of each temperature / fan-speed popover.
struct SettingsWorkflowPresetsView: View {
    @Environment(ServerSettingsStore.self) private var store

    var body: some View {
        SettingsForm("Quick Presets") {
            Section {
            } footer: {
                Text("These values appear as one-tap choices in the printer temperature and fan controls, next to the Off button.")
            }
            ForEach(SettingsWorkflowPresetCategory.all) { category in
                categorySection(category)
            }
        }
        .modifier(SettingsWorkflowKeyboardDone())
    }

    private func categorySection(_ category: SettingsWorkflowPresetCategory) -> some View {
        let raw = store.string(category.key)
        let values = category.values(from: raw)
        let lo = Double(category.range.lowerBound), hi = Double(category.range.upperBound)
        return Section {
            ForEach(0..<3, id: \.self) { index in
                LabeledContent("Preset \(index + 1)") {
                    SettingsWorkflowNumberInput(value: Double(values[index]), range: lo...hi, unit: category.unit) { newValue in
                        guard let newValue else { return }
                        var next = values
                        next[index] = Int(newValue)
                        Task { await store.save([category.key: .string(category.encode(next))]) }
                    }
                }
            }
            Button("Restore Defaults", systemImage: "arrow.counterclockwise") {
                Task { await store.save([category.key: .string("")]) }
            }
            .disabled(raw.isEmpty)
        } header: {
            Text(category.title)
        } footer: {
            Text("\(category.range.lowerBound)–\(category.range.upperBound) \(category.unit). Defaults: \(category.defaults.map(String.init).joined(separator: ", ")).")
        }
        .disabled(!store.canEdit)
    }
}

// MARK: - Preheat chamber targets

/// Edits the chamber temperature the preheat stage aims for, per filament type.
struct SettingsPreheatTargetsView: View {
    @Environment(ServerSettingsStore.self) private var store
    private let key = "preheat_filament_targets"

    var body: some View {
        let raw = store.string(key)
        let map = SettingsPreheatTargets.parse(raw)
        let enabled = store.bool("preheat_enabled")
        SettingsForm("Chamber Targets") {
            Section {
                ForEach(SettingsPreheatTargets.rows(for: map), id: \.self) { filament in
                    LabeledContent {
                        SettingsWorkflowNumberInput(
                            value: Double(SettingsPreheatTargets.value(for: filament, in: map)),
                            range: 0...Double(SettingsPreheatTargets.maxTemp),
                            unit: "°C"
                        ) { newValue in
                            guard let newValue else { return }
                            var next = map
                            next[filament] = Int(newValue)
                            Task { await store.save([key: .string(SettingsPreheatTargets.serialize(next))]) }
                        }
                    } label: {
                        if filament == "default" {
                            Text("Other Filaments").italic()
                        } else {
                            Text(filament)
                        }
                    }
                }
            } footer: {
                Text("When several filaments are loaded, the highest target wins. A target of 0 °C skips chamber heating, so PLA-only prints go straight to the bed phase. Maximum \(SettingsPreheatTargets.maxTemp) °C.")
            }
            .disabled(!enabled || !store.canEdit)

            Section {
                Button("Restore Defaults", systemImage: "arrow.counterclockwise") {
                    Task { await store.save([key: .string("")]) }
                }
                .disabled(raw.isEmpty || !store.canEdit)
            } footer: {
                if !enabled {
                    Text("Turn on Preheat & Heat Soak on the Print Workflow page to edit these targets.")
                }
            }
        }
        .modifier(SettingsWorkflowKeyboardDone())
    }
}

// MARK: - Drying presets

/// Edits drying temperature and duration per filament type for each AMS dryer model.
struct SettingsDryingPresetsView: View {
    @Environment(ServerSettingsStore.self) private var store
    private let key = "drying_presets"

    var body: some View {
        let raw = store.string(key)
        let rows = SettingsDryingPresets.parse(raw)
        SettingsForm("Drying Presets") {
            Section {
            } footer: {
                Text("Temperature and duration used when auto-drying each filament type. The AMS 2 Pro tops out at 65 °C; the AMS-HT can go up to 85 °C.")
            }
            ForEach(rows.indices, id: \.self) { index in
                let row = rows[index]
                Section(row.name) {
                    dryerRow("AMS 2 Pro", temp: row.preset.n3f, hours: row.preset.n3fHours,
                             tempRange: SettingsDryingPreset.amsProTempRange) { temp, hours in
                        update(rows, at: index) { preset in
                            if let temp { preset.n3f = temp }
                            if let hours { preset.n3fHours = hours }
                        }
                    }
                    dryerRow("AMS-HT", temp: row.preset.n3s, hours: row.preset.n3sHours,
                             tempRange: SettingsDryingPreset.amsHTTempRange) { temp, hours in
                        update(rows, at: index) { preset in
                            if let temp { preset.n3s = temp }
                            if let hours { preset.n3sHours = hours }
                        }
                    }
                }
                .disabled(!store.canEdit)
            }
            Section {
                Button("Restore Defaults", systemImage: "arrow.counterclockwise") {
                    Task { await store.save([key: .string("")]) }
                }
                .disabled(raw.isEmpty || !store.canEdit)
            }
        }
        .modifier(SettingsWorkflowKeyboardDone())
    }

    private func dryerRow(_ title: String, temp: Int, hours: Int, tempRange: ClosedRange<Int>,
                          onChange: @escaping (Int?, Int?) -> Void) -> some View {
        LabeledContent(title) {
            HStack(spacing: 12) {
                SettingsWorkflowNumberInput(value: Double(temp),
                                            range: Double(tempRange.lowerBound)...Double(tempRange.upperBound),
                                            unit: "°C", width: 48) { value in
                    if let value { onChange(Int(value), nil) }
                }
                SettingsWorkflowNumberInput(value: Double(hours),
                                            range: Double(SettingsDryingPreset.hoursRange.lowerBound)...Double(SettingsDryingPreset.hoursRange.upperBound),
                                            unit: "h", width: 40) { value in
                    if let value { onChange(nil, Int(value)) }
                }
            }
        }
    }

    private func update(_ rows: [(name: String, preset: SettingsDryingPreset)], at index: Int,
                        _ change: (inout SettingsDryingPreset) -> Void) {
        var next = rows
        change(&next[index].preset)
        let json = SettingsDryingPresets.serialize(next)
        Task { await store.save([key: .string(json)]) }
    }
}

// MARK: - Humidity triggers

/// Edits the per-filament humidity level that triggers auto-drying and humidity alarms.
struct SettingsDryingHumidityView: View {
    @Environment(ServerSettingsStore.self) private var store
    private let key = "ams_humidity_thresholds"

    var body: some View {
        let raw = store.string(key)
        let map = SettingsDryingHumidity.parse(raw)
        let fair = store.int("ams_humidity_fair") ?? 60
        let range = Double(SettingsDryingHumidity.range.lowerBound)...Double(SettingsDryingHumidity.range.upperBound)
        SettingsForm("Humidity Triggers") {
            Section {
                row("default", label: Text("All Filaments").italic(), map: map, fair: fair,
                    inherited: fair, range: range)
            } footer: {
                Text("Leave empty to use the AMS \"fair\" humidity threshold (\(fair)%).")
            }
            Section {
                ForEach(SettingsDryingHumidity.rows(for: map).filter { $0 != "default" }, id: \.self) { filament in
                    row(filament, label: Text(filament), map: map, fair: fair,
                        inherited: SettingsDryingHumidity.resolved("default", in: map, fair: fair), range: range)
                }
            } header: {
                Text("By Filament")
            } footer: {
                Text("Drying starts (and alarms fire) when an AMS's humidity rises above the threshold for its filament. With mixed filaments in one unit, the lowest threshold applies. Empty fields use the value above. Allowed range \(SettingsDryingHumidity.range.lowerBound)–\(SettingsDryingHumidity.range.upperBound)%.")
            }
            Section {
                Button("Clear All Overrides", systemImage: "arrow.counterclockwise") {
                    Task { await store.save([key: .string("")]) }
                }
                .disabled(map.isEmpty || !store.canEdit)
            }
        }
        .modifier(SettingsWorkflowKeyboardDone())
    }

    private func row(_ key: String, label: Text, map: [String: Int], fair: Int, inherited: Int,
                     range: ClosedRange<Double>) -> some View {
        LabeledContent {
            SettingsWorkflowNumberInput(
                value: map[key].map(Double.init),
                placeholder: String(inherited),
                range: range,
                unit: "%",
                allowsEmpty: true
            ) { newValue in
                var next = map
                next[key] = newValue.map { Int($0) }
                Task { await store.save([self.key: .string(SettingsDryingHumidity.serialize(next))]) }
            }
        } label: {
            label
        }
        .disabled(!store.canEdit)
    }
}
