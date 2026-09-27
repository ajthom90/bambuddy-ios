import SwiftUI

/// Configures what filament an AMS / external slot holds (preset, color, temperatures, K-profile).
struct ConfigureSlotView: View {
    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let printerId: Int
    let amsId: Int
    let trayId: Int
    let tray: AMSTray

    @State private var catalog = PrinterFilamentCatalog()
    @State private var runner = ActionRunner()
    @State private var loading = true
    @State private var preset: PrinterFilamentChoice?
    @State private var typeOverride: String?
    @State private var colorHex = ""
    @State private var tempMin = 190
    @State private var tempMax = 230
    @State private var profiles: [PrinterKProfile] = []
    @State private var profilesError: String?
    @State private var selectedProfileKey: String?
    @State private var profileTouched = false
    @State private var spoolDefaults: PrinterSpoolDefaults?
    @State private var savedPresetId: String?
    @State private var extruderMap: [String: Int] = [:]
    @State private var colorCatalog: [PrinterColorCatalogEntry] = []
    @State private var showPicker = false
    @State private var showExtendedColors = false
    @State private var confirmReset = false
    @State private var done: String?
    @State private var keepSlotTemps = false

    private var client: APIClient { session.client }
    private var status: PrinterStatus? { store.statuses[printerId] }
    private var printer: Printer? { store.printer(printerId) }
    private var canControl: Bool { session.can("printers:control") }
    private var isDual: Bool { (printer?.nozzleCount ?? 1) >= 2 || (status?.isDualNozzle ?? false) }

    // MARK: Slot facts

    private var slotLabel: String {
        if amsId == 255 {
            guard isDual else { return "External Spool" }
            return trayId == 0 ? "External (Left)" : "External (Right)"
        }
        if amsId >= 128 { return "AMS HT \(letter(amsId - 128))" }
        return "AMS \(letter(amsId)) · Slot \(trayId + 1)"
    }

    private func letter(_ i: Int) -> String { String(Character(UnicodeScalar(65 + max(0, min(i, 25)))!)) }

    /// Extruder feeding this slot (1 = left, 0 = right), when known.
    private var slotExtruder: Int? {
        if amsId == 255 { return isDual ? (trayId == 0 ? 1 : 0) : nil }
        return extruderMap[String(amsId)]
    }

    private var nozzleDiameter: String {
        let nozzles = status?.nozzles ?? []
        let index = amsId == 255 ? 0 : (extruderMap[String(amsId)] ?? 0)
        if nozzles.indices.contains(index), let d = nozzles[index].nozzleDiameter, !d.isEmpty { return d }
        if let d = nozzles.first?.nozzleDiameter, !d.isEmpty { return d }
        return spoolDefaults?.nozzleDiameter ?? "0.4"
    }

    private var trayType: String { typeOverride ?? preset?.trayType ?? (tray.trayType?.isEmpty == false ? tray.trayType! : "PLA") }

    private var normalizedHex: String? {
        var s = colorHex.trimmingCharacters(in: .whitespaces).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        s = s.filter { "0123456789ABCDEF".contains($0) }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        if s.count == 8 { s = String(s.prefix(6)) }
        return s.count == 6 ? s : nil
    }

    private var matching: [PrinterKProfile] {
        PrinterFilamentLogic.matchingProfiles(profiles, preset: preset, activeCaliIdx: tray.caliIdx, extruder: slotExtruder)
    }

    private var others: [PrinterKProfile] {
        let used = Set(matching.map(profileKey))
        return PrinterFilamentLogic.dedupe(profiles.filter { !used.contains(profileKey($0)) })
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func profileKey(_ p: PrinterKProfile) -> String { "\(p.slotId)|\(p.extruder)" }

    private var selectedProfile: PrinterKProfile? {
        guard let key = selectedProfileKey else { return nil }
        return profiles.first { profileKey($0) == key }
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            Form {
                header
                presetSection
                colorSection
                temperatureSection
                kProfileSection
                if canControl {
                    Section {
                        Button("Reset Slot", role: .destructive) { confirmReset = true }
                    } footer: {
                        Text("Clears the slot's filament information on the printer.")
                    }
                }
            }
            .navigationTitle("Configure Slot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { Task { await configure() } }
                        .disabled(preset == nil || !canControl || runner.isRunning || tempMin > tempMax)
                }
            }
            .disabled(runner.isRunning)
            .overlay {
                if let done {
                    Label(done, systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .padding(20)
                        .glassEffect(.regular, in: .rect(cornerRadius: 18))
                        .transition(.scale.combined(with: .opacity))
                } else if runner.isRunning {
                    ProgressView().controlSize(.large)
                }
            }
            .actionAlerts(runner)
            .confirm("Reset this slot?", isPresented: $confirmReset, message: "The printer forgets the filament type, color and temperatures for \(slotLabel).", action: "Reset") {
                Task { await reset() }
            }
            .sheet(isPresented: $showPicker) {
                PrinterFilamentPresetPicker(printerId: printerId, selection: $preset, nozzle: nozzleDiameter, catalog: catalog)
            }
            .onChange(of: preset) { old, new in
                guard old != new else { return }
                typeOverride = nil
                if keepSlotTemps {
                    keepSlotTemps = false
                } else if let new {
                    let t = new.tempRange
                    tempMin = t.min
                    tempMax = t.max
                }
                if !profileTouched { autoSelectProfile() }
            }
            .task { await loadAll() }
        }
    }

    @ViewBuilder
    private var header: some View {
        Section {
            HStack(spacing: 12) {
                ColorSwatch(hex: normalizedHex ?? tray.trayColor, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(slotLabel).font(.headline)
                    Text(tray.isEmpty ? "Empty" : [tray.trayType, tray.traySubBrands].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let ext = slotExtruder, isDual {
                        Text(ext == 1 ? "Left nozzle · \(nozzleDiameter) mm" : "Right nozzle · \(nozzleDiameter) mm").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var presetSection: some View {
        Section {
            Button { showPicker = true } label: {
                HStack {
                    Text("Preset").foregroundStyle(.primary)
                    Spacer()
                    if loading && preset == nil {
                        ProgressView()
                    } else {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(preset?.name ?? "Choose…").foregroundStyle(preset == nil ? .secondary : .primary).lineLimit(2).multilineTextAlignment(.trailing)
                            if let preset { Text(preset.source.label).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            Picker("Material", selection: Binding(get: { trayType }, set: { typeOverride = $0 })) {
                ForEach(materialOptions, id: \.self) { Text($0).tag($0) }
            }
        } header: {
            Text("Filament")
        } footer: {
            if catalog.cloudUnavailable && catalog.loaded {
                Text("Bambu Cloud presets are unavailable (not signed in). Built-in and local presets are shown.")
            }
        }
    }

    private var materialOptions: [String] {
        var list = PrinterFilamentLogic.materials
        if !list.contains(trayType) { list.insert(trayType, at: 0) }
        return list
    }

    @ViewBuilder
    private var colorSection: some View {
        Section("Color") {
            HStack {
                ColorPicker("Color", selection: Binding(
                    get: { Color(hex: normalizedHex) ?? .white },
                    set: { colorHex = $0.hexString }
                ), supportsOpacity: false)
            }
            LabeledContent("Hex") {
                HStack {
                    TextField("RRGGBB", text: $colorHex)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        .font(.body.monospaced())
                    if !colorHex.isEmpty {
                        Button { colorHex = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain)
                    }
                }
            }
            swatchGrid(showExtendedColors ? Self.basicColors + Self.extendedColors : Self.basicColors)
            Button(showExtendedColors ? "Fewer Colors" : "More Colors") { withAnimation { showExtendedColors.toggle() } }
                .font(.subheadline)
            let catalogMatches = matchingCatalogColors
            if !catalogMatches.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(catalogMatches) { entry in
                            Button { colorHex = String(entry.hexColor.replacingOccurrences(of: "#", with: "").prefix(6)) } label: {
                                HStack(spacing: 6) {
                                    ColorSwatch(hex: entry.hexColor, size: 18)
                                    Text(entry.colorName).font(.caption).lineLimit(1)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(.quaternary.opacity(0.6), in: .capsule)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func swatchGrid(_ colors: [(String, String)]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 34), spacing: 10)], spacing: 10) {
            ForEach(colors, id: \.1) { name, hex in
                Button { colorHex = hex } label: {
                    ColorSwatch(hex: hex, size: 30)
                        .overlay { if normalizedHex == hex { Circle().strokeBorder(Color.accentColor, lineWidth: 3) } }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(name)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var temperatureSection: some View {
        Section {
            Stepper(value: $tempMin, in: 150...350, step: 5) {
                LabeledContent("Minimum", value: "\(tempMin) °C")
            }
            Stepper(value: $tempMax, in: 150...350, step: 5) {
                LabeledContent("Maximum", value: "\(tempMax) °C")
            }
        } header: {
            Text("Nozzle Temperature")
        } footer: {
            if tempMin > tempMax { Text("The minimum must not exceed the maximum.").foregroundStyle(.red) }
        }
    }

    @ViewBuilder
    private var kProfileSection: some View {
        Section {
            Picker("K-Profile", selection: Binding(get: { selectedProfileKey }, set: { selectedProfileKey = $0; profileTouched = true })) {
                Text("None (printer default)").tag(String?.none)
                if !matching.isEmpty {
                    Section("Matching") {
                        ForEach(matching, id: \.self) { p in Text(profileLabel(p)).tag(Optional(profileKey(p))) }
                    }
                }
                if !others.isEmpty {
                    Section("Other K-Profiles") {
                        ForEach(others, id: \.self) { p in Text(profileLabel(p)).tag(Optional(profileKey(p))) }
                    }
                }
            }
            .pickerStyle(.navigationLink)
            if let p = selectedProfile {
                InfoRow("K Value", p.kDisplay)
            }
        } header: {
            Text("Pressure Advance")
        } footer: {
            if let profilesError {
                Text("K-profiles unavailable: \(profilesError)")
            } else if preset == nil {
                Text("Choose a filament preset to see matching K-profiles.")
            } else if matching.isEmpty {
                Text("No K-profiles match \(PrinterFilamentLogic.stripSuffix(preset?.name ?? "")) for \(nozzleDiameter) mm nozzles.")
            } else if let k = spoolDefaults?.kValue, spoolDefaults?.caliIdx != nil {
                Text("The assigned spool was calibrated with K = \(String(format: "%.3f", k)).")
            }
        }
    }

    private func profileLabel(_ p: PrinterKProfile) -> String {
        let extruders = Set(profiles.map(\.extruder))
        var label = "\(p.displayName) (K=\(p.kDisplay))"
        if extruders.count > 1 { label += p.extruder == 1 ? " · Left" : " · Right" }
        return label
    }

    private var matchingCatalogColors: [PrinterColorCatalogEntry] {
        guard let preset, !colorCatalog.isEmpty else { return [] }
        let parsed = preset.parsed
        let material = parsed.material.uppercased()
        guard !material.isEmpty else { return [] }
        let brand = parsed.brand.lowercased()
        let hits = colorCatalog.filter { entry in
            guard (entry.material ?? "").uppercased().contains(material) else { return false }
            if brand.isEmpty || brand == "generic" { return true }
            let maker = entry.manufacturer.lowercased()
            let makerHead = maker.split(separator: " ").first.map(String.init) ?? maker
            return brand.contains(makerHead) || maker.contains(brand)
        }
        return Array(hits.prefix(40))
    }

    // MARK: Loading

    private func loadAll() async {
        colorHex = String((tray.trayColor ?? "").prefix(6)).uppercased()
        if colorHex == "000000", (tray.trayColor ?? "").hasSuffix("00"), tray.isEmpty { colorHex = "" }
        if let min = tray.nozzleTempMin, min > 0 { tempMin = min }
        if let max = tray.nozzleTempMax, max > 0 { tempMax = max }

        async let statusReq: JSONValue? = try? client.get("printers/\(printerId)/status")
        async let presetsReq: [String: PrinterSlotPreset]? = try? client.get("printers/\(printerId)/slot-presets")
        async let defaultsReq: PrinterSpoolDefaults? = try? client.get("printers/\(printerId)/slots/\(amsId)/\(trayId)/spool-defaults")
        async let colorsReq: [PrinterColorCatalogEntry]? = try? client.get("inventory/colors")
        let (statusJSON, presets, defaults, colors) = await (statusReq, presetsReq, defaultsReq, colorsReq)
        var map: [String: Int] = [:]
        for (k, v) in statusJSON?["ams_extruder_map"]?.objectValue ?? [:] { if let i = v.intValue { map[k] = i } }
        extruderMap = map
        spoolDefaults = defaults
        colorCatalog = colors ?? []
        let key = amsId >= 128 && amsId <= 135 ? amsId : amsId * 4 + trayId
        savedPresetId = presets?[String(key)]?.presetId

        async let profilesTask: Void = loadProfiles()
        await catalog.load(client: client)
        await profilesTask
        selectInitialPreset()
        loading = false
        if !profileTouched { autoSelectProfile() }
    }

    private func loadProfiles() async {
        do {
            let r: PrinterKProfilesResponse = try await client.get("printers/\(printerId)/kprofiles/", query: ["nozzle_diameter": .string(nozzleDiameter)])
            profiles = r.profiles
            profilesError = nil
        } catch {
            profilesError = error.localizedDescription
        }
    }

    private func selectInitialPreset() {
        let trayIdx = tray.trayInfoIdx ?? ""
        var keep: Set<String> = []
        if let s = spoolDefaults?.slicerFilament { keep.insert(s) }
        if let s = savedPresetId { keep.insert(s) }
        if !trayIdx.isEmpty { keep.insert(trayIdx) }
        let all = catalog.choices(printerModel: PrinterFilamentLogic.modelCode(printer?.model), nozzle: nozzleDiameter, keepIds: keep)
        var pick: PrinterFilamentChoice?
        if let s = spoolDefaults?.slicerFilament, !s.isEmpty { pick = catalog.find(s, in: all) }
        if pick == nil, let s = savedPresetId, !s.isEmpty { pick = catalog.find(s, in: all) }
        if pick == nil, !trayIdx.isEmpty {
            pick = all.first { $0.source == .cloud && $0.rawId == trayIdx }
                ?? all.first { $0.source == .cloud && PrinterFilamentLogic.convertToTrayInfoIdx($0.rawId) == trayIdx }
            if pick == nil, catalog.cloud.isEmpty { pick = all.first { $0.id == "builtin_\(trayIdx)" } }
        }
        if let pick {
            // Keep the slot's reported temperatures when it already holds this filament.
            keepSlotTemps = (tray.nozzleTempMin ?? 0) > 0 && (tray.nozzleTempMax ?? 0) > 0
            preset = pick
        }
    }

    private func autoSelectProfile() {
        let ext = spoolDefaults?.extruder ?? slotExtruder
        if let cali = spoolDefaults?.caliIdx, let p = profiles.first(where: { $0.slotId == cali && (ext == nil || $0.extruder == ext) }) {
            selectedProfileKey = profileKey(p); return
        }
        if let cali = tray.caliIdx, cali > 0, let p = profiles.first(where: { $0.slotId == cali && (slotExtruder == nil || $0.extruder == slotExtruder) }) {
            selectedProfileKey = profileKey(p); return
        }
        selectedProfileKey = matching.first.map(profileKey)
    }

    // MARK: Actions

    private func configure() async {
        guard let preset else { return }
        await runner.run {
            var ids = preset.baseIdentifiers
            if preset.source == .cloud, !preset.rawId.hasPrefix("GFS") {
                if let detail: PrinterCloudSettingDetail = try? await client.get("cloud/settings/\(preset.rawId)"),
                   let fid = detail.filamentId, !fid.isEmpty {
                    ids.trayInfoIdx = fid
                }
            }
            let color = (normalizedHex ?? String((tray.trayColor ?? "").prefix(6)).nonEmpty ?? "FFFFFF") + "FF"
            var query: [String: QueryValue?] = [
                "tray_info_idx": .string(ids.trayInfoIdx),
                "tray_type": .string(trayType),
                "tray_sub_brands": .string(preset.subBrands),
                "tray_color": .string(color.uppercased()),
                "nozzle_temp_min": .int(tempMin),
                "nozzle_temp_max": .int(tempMax),
                "cali_idx": .int(selectedProfile?.slotId ?? -1),
                "nozzle_diameter": .string(nozzleDiameter),
            ]
            if !ids.settingId.isEmpty { query["setting_id"] = .string(ids.settingId) }
            if let p = selectedProfile {
                if !p.filamentId.isEmpty { query["kprofile_filament_id"] = .string(p.filamentId) }
                if let s = p.settingId, !s.isEmpty { query["kprofile_setting_id"] = .string(s) }
                if let k = p.kDouble, k > 0 { query["k_value"] = .double(k) }
            }
            try await client.call(.post, "printers/\(printerId)/slots/\(amsId)/\(trayId)/configure", query: query)
            // Remember the preset for this slot; failures here are not fatal.
            try? await client.call(.put, "printers/\(printerId)/slot-presets/\(amsId)/\(trayId)", query: [
                "preset_id": .string(preset.id),
                "preset_name": .string(preset.subBrands),
                "preset_source": .string(preset.source.rawValue),
            ])
            await finish("Slot configured")
        }
    }

    private func reset() async {
        await runner.run {
            try await client.call(.post, "printers/\(printerId)/ams/\(amsId)/tray/\(trayId)/reset")
            await finish("Slot reset")
        }
    }

    private func finish(_ message: String) async {
        withAnimation { done = message }
        Task { await store.refreshStatus(printerId) }
        try? await Task.sleep(for: .seconds(1.2))
        dismiss()
    }

    // MARK: Palette

    static let basicColors: [(String, String)] = [
        ("White", "FFFFFF"), ("Black", "000000"), ("Red", "E53935"), ("Blue", "1E88E5"),
        ("Green", "43A047"), ("Yellow", "FDD835"), ("Orange", "FB8C00"), ("Gray", "9E9E9E"),
    ]

    static let extendedColors: [(String, String)] = [
        ("Cyan", "00BCD4"), ("Magenta", "D81B60"), ("Purple", "8E24AA"), ("Pink", "F48FB1"),
        ("Brown", "6D4C41"), ("Beige", "D7C4A3"), ("Navy", "1A237E"), ("Teal", "00897B"),
        ("Lime", "C0CA33"), ("Gold", "C9A227"), ("Silver", "BDBDBD"), ("Bronze", "A0522D"),
        ("Maroon", "800000"), ("Olive", "808000"), ("Coral", "FF7F50"), ("Salmon", "FA8072"),
        ("Turquoise", "40E0D0"), ("Violet", "7F00FF"), ("Indigo", "3F51B5"), ("Ivory", "FFFFF0"),
        ("Charcoal", "36454F"), ("Mint", "98FF98"), ("Sky Blue", "87CEEB"), ("Light Gray", "D3D3D3"),
    ]
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
