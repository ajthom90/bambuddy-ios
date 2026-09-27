import SwiftUI

/// Constants shared by the spool form and bulk editor.
enum InventoryFormOptions {
    static let materials = ["PLA", "PETG", "ABS", "ASA", "TPU", "PC", "PA", "PVA", "HIPS", "PCTG", "PLA-CF", "PETG-CF", "PA-CF", "PA6-GF", "PPS", "BVOH"]
    static let brands = ["Bambu", "Bambu Lab", "Polymaker", "PolyLite", "PolyTerra", "eSUN", "Overture", "Elegoo", "SUNLU", "Inland", "Hatchbox", "Prusament", "Jayo", "Generic"]
    static let subtypes = ["Basic", "Matte", "Silk", "Silk+", "Tough", "Tough+", "HF", "High Flow", "CF", "GF", "Galaxy", "Glow",
                           "Marble", "Metal", "Rainbow", "Sparkle", "Wood", "Translucent", "Clear", "Lite", "Pro", "Plus", "Aero",
                           "95A", "85A", "Gradient", "Dual Color", "Tri Color", "Multicolor", "Support", "ESD"]
    static let labelWeights = [250, 500, 750, 1000, 2000, 3000, 5000]
    static let effects = ["sparkle", "wood", "marble", "glow", "matte", "silk", "galaxy", "rainbow", "metal", "translucent",
                          "gradient", "dual-color", "tri-color", "multicolor"]
    static let nozzleDiameters = ["0.2", "0.4", "0.6", "0.8"]
}

/// Editable copy of a spool's fields.
private struct InventorySpoolDraft {
    var material = ""
    var subtype = ""
    var brand = ""
    var colorName = ""
    var rgba = "808080FF"
    var extraColors = ""
    var effectType = ""
    var labelWeight = 1000
    var coreWeight = 250
    var coreWeightCatalogId: Int?
    var weightUsed: Double = 0
    var slicerFilament = ""
    var slicerFilamentName = ""
    var note = ""
    var costPerKg: Double?
    var category = ""
    var lowStockThresholdPct: Int?
    var locationId: Int?
    var spoolmanFilamentId: Int?

    init() {}

    init(_ s: InventorySpool) {
        material = s.material ?? ""
        subtype = s.subtype ?? ""
        brand = s.brand ?? ""
        colorName = s.colorNameIsSynthesized == true ? "" : (s.colorName ?? "")
        rgba = s.rgba ?? "808080FF"
        extraColors = s.extraColors ?? ""
        effectType = s.effectType ?? ""
        labelWeight = s.labelWeight ?? 1000
        coreWeight = s.coreWeight ?? 250
        coreWeightCatalogId = s.coreWeightCatalogId
        weightUsed = s.weightUsed ?? 0
        slicerFilament = s.slicerFilament ?? ""
        slicerFilamentName = s.slicerFilamentName ?? ""
        note = s.note ?? ""
        costPerKg = s.costPerKg
        category = s.category ?? ""
        lowStockThresholdPct = s.lowStockThresholdPct
        locationId = s.locationId
    }

    var remaining: Double { max(0, Double(labelWeight) - weightUsed) }

    private func text(_ s: String) -> JSONValue {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? .null : .string(t)
    }

    func payload(includeWeight: Bool, includeLocation: Bool) -> [String: JSONValue] {
        var p: [String: JSONValue] = [
            "material": text(material),
            "subtype": text(subtype),
            "brand": text(brand),
            "color_name": text(colorName),
            "rgba": text(rgba),
            "extra_colors": text(extraColors),
            "effect_type": text(effectType),
            "label_weight": .number(Double(labelWeight)),
            "core_weight": .number(Double(coreWeight)),
            "core_weight_catalog_id": coreWeightCatalogId.map { .number(Double($0)) } ?? .null,
            "slicer_filament": text(slicerFilament),
            "slicer_filament_name": text(slicerFilamentName),
            "note": text(note),
            "cost_per_kg": costPerKg.map { .number($0) } ?? .null,
            "category": text(category),
            "low_stock_threshold_pct": lowStockThresholdPct.map { .number(Double($0)) } ?? .null,
        ]
        if let spoolmanFilamentId { p["spoolman_filament_id"] = .number(Double(spoolmanFilamentId)) }
        if includeWeight { p["weight_used"] = .number(min(max(0, weightUsed), Double(labelWeight))) }
        if includeLocation { p["location_id"] = locationId.map { .number(Double($0)) } ?? .null }
        return p
    }
}

struct InventorySpoolFormView: View {
    @Environment(AppSession.self) private var session
    @Environment(InventoryStore.self) private var store
    @Environment(PrinterStore.self) private var printers
    @Environment(\.dismiss) private var dismiss
    let request: InventoryFormRequest

    @State private var draft = InventorySpoolDraft()
    @State private var loaded = false
    @State private var quickAdd = false
    @State private var quantity = 1
    @State private var weightTouched = false
    @State private var locationTouched = false
    @State private var presetOptions: [InventoryPresetOption] = []
    @State private var catalogColors: [InventoryColorEntry] = []
    @State private var kProfiles: [InventoryKProfileInput] = []
    @State private var filamentPresets: [InventoryFilamentPresetInput] = []
    @State private var originalK: [InventoryKProfileInput] = []
    @State private var originalPresets: [InventoryFilamentPresetInput] = []
    @State private var showNewLocation = false
    @State private var newLocationName = ""
    @State private var showAddK = false
    @State private var showAddPreset = false
    @State private var validation: String?
    @State private var runner = ActionRunner()

    private var editingId: Int? { if case .edit(let id) = request { return id }; return nil }
    private var sourceSpool: InventorySpool? {
        switch request {
        case .create: nil
        case .edit(let id), .copy(let id): store.spool(id)
        }
    }
    private var isCreate: Bool { editingId == nil }
    private var title: String {
        switch request {
        case .create: "Add Spool"
        case .edit: "Edit Spool"
        case .copy: "Duplicate Spool"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if case .create = request {
                    Section {
                        Toggle("Quick Add", isOn: $quickAdd)
                    } footer: {
                        Text("Quick add only needs a material; everything else can be filled in later.")
                    }
                }
                if isCreate {
                    Section {
                        Stepper(value: $quantity, in: 1...50) {
                            LabeledContent("Quantity", value: "\(quantity) \(quantity == 1 ? "spool" : "spools")")
                        }
                    }
                }
                if store.isSpoolman && isCreate { spoolmanSection }
                filamentSection
                colorSection
                weightSection
                if !quickAdd { inventorySection }
                if editingId != nil && !quickAdd { profilesSection }
                if let validation {
                    Section { Label(validation, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editingId == nil ? (quantity > 1 ? "Add \(quantity)" : "Add") : "Save") { save() }
                        .disabled(runner.isRunning)
                }
            }
            .task { await prepare() }
            .task(id: "\(draft.brand)|\(draft.material)") { await loadCatalogColors() }
            .alert("New Storage Location", isPresented: $showNewLocation) {
                TextField("Name", text: $newLocationName)
                Button("Create") {
                    let name = newLocationName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    Task {
                        await runner.run {
                            let loc = try await store.createLocation(name: name, identifier: nil)
                            draft.locationId = loc.id
                            locationTouched = true
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: $showAddK) {
                InventoryKProfilePicker { new in
                    kProfiles.removeAll { $0.printerId == new.printerId && $0.extruder == new.extruder && $0.nozzleDiameter == new.nozzleDiameter }
                    kProfiles.append(new)
                }
            }
            .sheet(isPresented: $showAddPreset) {
                InventoryModelPresetPicker(options: presetOptions) { new in
                    filamentPresets.removeAll { $0.printerModel == new.printerModel && $0.nozzleDiameter == new.nozzleDiameter }
                    filamentPresets.append(new)
                }
            }
            .actionAlerts(runner)
            .interactiveDismissDisabled(runner.isRunning)
        }
    }

    // MARK: Sections

    @State private var spoolmanFilaments: [InventorySpoolmanFilament] = []

    private var spoolmanSection: some View {
        Section {
            Picker("Spoolman Filament", selection: Binding(get: { draft.spoolmanFilamentId }, set: { id in
                draft.spoolmanFilamentId = id
                if let f = spoolmanFilaments.first(where: { $0.id == id }) {
                    if let m = f.material { draft.material = m }
                    if let v = f.vendor?.name { draft.brand = v }
                    if let hex = f.colorHex, let rgba = InventoryColors.normalizedRGBA(hex) { draft.rgba = rgba }
                    if let c = f.colorName { draft.colorName = c }
                    if let w = f.weight { draft.labelWeight = w }
                    if let sw = f.spoolWeight { draft.coreWeight = Int(sw) }
                }
            })) {
                Text("New filament").tag(Int?.none)
                ForEach(spoolmanFilaments) { f in Text(f.label).tag(Int?.some(f.id)) }
            }
        } header: {
            Text("Spoolman")
        } footer: {
            Text("Pick an existing Spoolman filament, or leave “New filament” to create one from the fields below.")
        }
        .task {
            if spoolmanFilaments.isEmpty {
                spoolmanFilaments = ((try? await store.client.get("spoolman/inventory/filaments", as: [InventorySpoolmanFilament].self)) ?? [])
                    .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
            }
        }
    }

    private var filamentSection: some View {
        Section {
            if !quickAdd {
                NavigationLink {
                    InventoryPresetPickerView(options: presetOptions, selectedCode: draft.slicerFilament) { option in
                        if let option {
                            draft.slicerFilament = option.code
                            draft.slicerFilamentName = option.name
                            let parsed = InventoryPresets.parse(option.name)
                            if draft.material.isEmpty { draft.material = parsed.material }
                            if draft.brand.isEmpty { draft.brand = parsed.brand }
                            if draft.subtype.isEmpty { draft.subtype = parsed.subtype }
                        } else {
                            draft.slicerFilament = ""
                            draft.slicerFilamentName = ""
                        }
                    }
                } label: {
                    LabeledContent("Slicer Preset") {
                        Text(draft.slicerFilamentName.isEmpty ? (draft.slicerFilament.isEmpty ? "None" : draft.slicerFilament) : draft.slicerFilamentName)
                            .lineLimit(1)
                    }
                }
            }
            InventorySuggestField(title: "Material", text: $draft.material, suggestions: materialSuggestions, capitalization: .characters)
            InventorySuggestField(title: "Subtype", text: $draft.subtype, suggestions: InventoryFormOptions.subtypes)
            InventorySuggestField(title: "Brand", text: $draft.brand, suggestions: brandSuggestions)
        } header: {
            Text("Filament")
        } footer: {
            if isCreate && !quickAdd && !store.isSpoolman {
                Text("A slicer preset, material, brand and subtype are required. Choosing a preset fills in the rest.")
            }
        }
    }

    private var materialSuggestions: [String] {
        Array(Set(InventoryFormOptions.materials + store.spools.compactMap(\.material).filter { !$0.isEmpty })).sorted()
    }

    private var brandSuggestions: [String] {
        Array(Set(InventoryFormOptions.brands + store.spools.compactMap(\.brand).filter { !$0.isEmpty })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var colorSection: some View {
        Section {
            HStack {
                InventorySpoolSwatch(rgba: draft.rgba, extraColors: draft.extraColors, effectType: draft.effectType, size: 36)
                TextField("Color name", text: $draft.colorName)
                ColorPicker("Color", selection: Binding(get: {
                    InventoryColors.color(draft.rgba) ?? .gray
                }, set: { draft.rgba = InventoryColors.rgba(from: $0) }), supportsOpacity: false)
                .labelsHidden()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(InventoryColors.quickPalette, id: \.1) { name, hex in
                        Button {
                            draft.rgba = hex
                            if draft.colorName.isEmpty { draft.colorName = name }
                        } label: {
                            InventorySpoolSwatch(rgba: hex, size: 28)
                                .overlay { if draft.rgba.uppercased() == hex { Circle().strokeBorder(Color.accentColor, lineWidth: 3) } }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(name)
                    }
                }
                .padding(.vertical, 2)
            }
            TextField("Hex (RRGGBB or RRGGBBAA)", text: Binding(get: { draft.rgba }, set: { v in
                draft.rgba = v.uppercased().replacingOccurrences(of: "#", with: "")
            }))
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .font(.body.monospaced())
            if !quickAdd {
                TextField("Gradient stops, e.g. FFA500,00AE42", text: $draft.extraColors)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                Picker("Effect", selection: $draft.effectType) {
                    Text("None").tag("")
                    ForEach(InventoryFormOptions.effects, id: \.self) { Text($0.capitalized).tag($0) }
                }
            }
            if !catalogColors.isEmpty {
                NavigationLink {
                    InventoryCatalogColorPicker(colors: catalogColors) { entry in
                        draft.colorName = entry.colorName
                        if let rgba = InventoryColors.normalizedRGBA(entry.hexColor) { draft.rgba = rgba }
                        draft.extraColors = entry.extraColors ?? ""
                        draft.effectType = entry.effectType ?? ""
                    }
                } label: {
                    Label("Catalog Colors (\(catalogColors.count))", systemImage: "paintpalette")
                }
            }
        } header: {
            Text("Color")
        }
    }

    private var weightSection: some View {
        Section {
            Picker("Label Weight", selection: $draft.labelWeight) {
                ForEach(Array(Set(InventoryFormOptions.labelWeights + [draft.labelWeight])).sorted(), id: \.self) { w in
                    Text(InventoryFormat.grams(Double(w))).tag(w)
                }
            }
            LabeledContent("Custom Label Weight") {
                TextField("g", value: $draft.labelWeight, format: .number).keyboardType(.numberPad).multilineTextAlignment(.trailing)
            }
            if !store.isSpoolman {
                NavigationLink {
                    InventoryCatalogWeightPicker(selectedId: draft.coreWeightCatalogId) { entry in
                        draft.coreWeightCatalogId = entry?.id
                        if let entry { draft.coreWeight = entry.weight }
                    }
                } label: {
                    LabeledContent("Empty Spool Type", value: store.catalogEntry(draft.coreWeightCatalogId)?.name ?? "Custom")
                }
            }
            LabeledContent("Empty Spool Weight") {
                TextField("g", value: Binding(get: { draft.coreWeight }, set: { draft.coreWeight = $0; draft.coreWeightCatalogId = nil }), format: .number)
                    .keyboardType(.numberPad).multilineTextAlignment(.trailing)
            }
            LabeledContent("Remaining") {
                TextField("g", value: Binding(get: { Int(draft.remaining.rounded()) }, set: { r in
                    draft.weightUsed = max(0, Double(draft.labelWeight) - Double(max(0, min(r, draft.labelWeight))))
                    weightTouched = true
                }), format: .number)
                .keyboardType(.numberPad).multilineTextAlignment(.trailing)
            }
            LabeledContent("Measured (with spool)") {
                TextField("g", value: Binding(get: { Int((draft.remaining + Double(draft.coreWeight)).rounded()) }, set: { g in
                    let remaining = max(0, min(Double(draft.labelWeight), Double(g - draft.coreWeight)))
                    draft.weightUsed = Double(draft.labelWeight) - remaining
                    weightTouched = true
                }), format: .number)
                .keyboardType(.numberPad).multilineTextAlignment(.trailing)
            }
        } header: {
            Text("Weight")
        } footer: {
            if editingId != nil && weightTouched && !store.isSpoolman {
                Text("Changing the remaining weight locks it against automatic AMS weight updates.")
            } else {
                Text("Enter either the remaining filament or the measured weight including the empty spool.")
            }
        }
    }

    private var inventorySection: some View {
        Section("Inventory") {
            LabeledContent("Cost per kg") {
                TextField(store.currencyCode, value: $draft.costPerKg, format: .number.precision(.fractionLength(0...2)))
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
            }
            if !store.isSpoolman {
                InventorySuggestField(title: "Category", text: $draft.category, suggestions: Array(Set(store.spools.compactMap(\.category).filter { !$0.isEmpty } + ["Stock"])).sorted())
                LabeledContent("Low Stock Below") {
                    TextField("\(Int(store.lowStockThreshold))% (global)", value: $draft.lowStockThresholdPct, format: .number)
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                }
            }
            Picker("Storage Location", selection: Binding(get: { draft.locationId }, set: { draft.locationId = $0; locationTouched = true })) {
                Text("None").tag(Int?.none)
                ForEach(store.locations) { Text($0.name).tag(Int?.some($0.id)) }
            }
            if session.can("inventory:update") {
                Button { newLocationName = ""; showNewLocation = true } label: { Label("New Location…", systemImage: "plus") }
            }
            TextField("Note", text: $draft.note, axis: .vertical).lineLimit(2...5)
        }
    }

    private var profilesSection: some View {
        Section {
            ForEach(kProfiles, id: \.self) { k in
                VStack(alignment: .leading, spacing: 2) {
                    Text(k.name ?? "K \(k.kValue)")
                    Text(InventoryFormat.joined([printers.printer(k.printerId)?.name ?? "Printer \(k.printerId)", "\(k.nozzleDiameter) mm", k.extruder == 1 ? "Left" : nil, "K \(k.kValue.formatted(.number.precision(.fractionLength(3))))"]))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .onDelete { kProfiles.remove(atOffsets: $0) }
            Button { showAddK = true } label: { Label("Add Pressure Advance Profile…", systemImage: "plus") }
                .disabled(printers.printers.isEmpty)
            ForEach(filamentPresets, id: \.self) { p in
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.slicerFilamentName ?? p.slicerFilament ?? "—")
                    Text("\(p.printerModel) · \(p.nozzleDiameter) mm").font(.caption).foregroundStyle(.secondary)
                }
            }
            .onDelete { filamentPresets.remove(atOffsets: $0) }
            Button { showAddPreset = true } label: { Label("Add Per-Printer Preset…", systemImage: "plus") }
        } header: {
            Text("Printer Profiles")
        } footer: {
            Text("Pressure-advance profiles and per-printer-model presets are applied when this spool is assigned to a slot.")
        }
    }

    // MARK: Loading & saving

    private func prepare() async {
        guard !loaded else { return }
        loaded = true
        if let spool = sourceSpool {
            draft = InventorySpoolDraft(spool)
            if case .copy = request {
                draft.weightUsed = 0
                weightTouched = true
                locationTouched = true
            }
        }
        if let id = editingId, let spool = store.spool(id) {
            kProfiles = (spool.kProfiles ?? []).map {
                InventoryKProfileInput(printerId: $0.printerId, extruder: $0.extruder ?? 0, nozzleDiameter: $0.nozzleDiameter ?? "0.4", nozzleType: $0.nozzleType, kValue: $0.kValue, name: $0.name, caliIdx: $0.caliIdx, settingId: $0.settingId)
            }
            originalK = kProfiles
            if !store.isDemo, let list = try? await store.filamentPresets(id) {
                filamentPresets = list.map { InventoryFilamentPresetInput(printerModel: $0.printerModel, nozzleDiameter: $0.nozzleDiameter ?? "0.4", slicerFilament: $0.slicerFilament, slicerFilamentName: $0.slicerFilamentName) }
                originalPresets = filamentPresets
            }
        }
        if !store.isDemo { presetOptions = await store.presetOptions() }
    }

    private func loadCatalogColors() async {
        guard !store.isDemo else { return }
        try? await Task.sleep(for: .milliseconds(400))
        let brand = draft.brand.trimmingCharacters(in: .whitespaces)
        let material = draft.material.trimmingCharacters(in: .whitespaces)
        guard !brand.isEmpty || !material.isEmpty else { catalogColors = []; return }
        let list = (try? await store.client.get("inventory/colors/search", query: ["manufacturer": .of(brand.isEmpty ? nil : brand), "material": .of(material.isEmpty ? nil : material)], as: [InventoryColorEntry].self)) ?? []
        catalogColors = list
    }

    private func validate() -> String? {
        if draft.material.trimmingCharacters(in: .whitespaces).isEmpty && draft.spoolmanFilamentId == nil { return "Material is required." }
        if isCreate && !quickAdd && !store.isSpoolman {
            if draft.slicerFilament.isEmpty { return "Choose a slicer preset (or turn on Quick Add)." }
            if draft.brand.trimmingCharacters(in: .whitespaces).isEmpty { return "Brand is required." }
            if draft.subtype.trimmingCharacters(in: .whitespaces).isEmpty { return "Subtype is required." }
        }
        if draft.labelWeight <= 0 { return "Label weight must be greater than zero." }
        if draft.coreWeight < 0 { return "Empty spool weight can't be negative." }
        if InventoryColors.normalizedRGBA(draft.rgba) == nil { return "Color must be a 6- or 8-digit hex value." }
        let stops = draft.extraColors.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if stops.count > 8 || stops.contains(where: { InventoryColors.normalizedRGBA($0) == nil }) { return "Gradient stops must be up to 8 comma-separated hex colors." }
        if let t = draft.lowStockThresholdPct, !(1...99).contains(t) { return "Low stock threshold must be between 1 and 99%." }
        return nil
    }

    private func save() {
        if let message = validate() { validation = message; return }
        validation = nil
        var d = draft
        d.rgba = InventoryColors.normalizedRGBA(d.rgba) ?? d.rgba
        let payload = d.payload(includeWeight: isCreate || weightTouched, includeLocation: isCreate || locationTouched)
        Task {
            await runner.run {
                if let id = editingId {
                    try await store.update(id, payload)
                    if kProfiles != originalK { try await store.saveKProfiles(id, kProfiles) }
                    if filamentPresets != originalPresets { try await store.saveFilamentPresets(id, filamentPresets) }
                    await store.load()
                } else {
                    try await store.create(payload, quantity: quantity)
                }
            }
            if runner.errorMessage == nil { dismiss() }
        }
    }
}

// MARK: - Helper views

/// Text field with a menu of suggested values.
struct InventorySuggestField: View {
    let title: String
    @Binding var text: String
    let suggestions: [String]
    var capitalization: TextInputAutocapitalization = .words

    var body: some View {
        HStack {
            TextField(title, text: $text)
                .textInputAutocapitalization(capitalization)
                .autocorrectionDisabled()
            let matches = filtered
            if !matches.isEmpty {
                Menu {
                    ForEach(matches, id: \.self) { s in Button(s) { text = s } }
                } label: {
                    Image(systemName: "chevron.up.chevron.down").foregroundStyle(.secondary)
                }
                .accessibilityLabel("\(title) suggestions")
            }
        }
    }

    private var filtered: [String] {
        let q = text.trimmingCharacters(in: .whitespaces).lowercased()
        let list = q.isEmpty || suggestions.contains(where: { $0.lowercased() == q }) ? suggestions : suggestions.filter { $0.lowercased().contains(q) }
        return Array(list.prefix(40))
    }
}

/// Searchable list of slicer presets.
struct InventoryPresetPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let options: [InventoryPresetOption]
    var selectedCode: String?
    let onSelect: (InventoryPresetOption?) -> Void
    @State private var search = ""

    var body: some View {
        let q = search.lowercased()
        let list = q.isEmpty ? options : options.filter { $0.name.lowercased().contains(q) || $0.code.lowercased().contains(q) }
        List {
            Button("No Preset") { onSelect(nil); dismiss() }
            ForEach(InventoryPresetOption.Source.allSourcesOrdered, id: \.self) { source in
                let items = list.filter { $0.source == source }
                if !items.isEmpty {
                    Section(source.rawValue) {
                        ForEach(items) { option in
                            Button {
                                onSelect(option)
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(option.name).foregroundStyle(.primary)
                                        Text(option.code).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if selectedCode == option.code || option.alternateCodes.contains(selectedCode ?? "\u{0}") {
                                        Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .overlay {
            if options.isEmpty {
                ContentUnavailableView("No Presets", systemImage: "list.bullet", description: Text("Sign in to Bambu Cloud or import local presets on the server to pick slicer presets."))
            } else if list.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
        .navigationTitle("Slicer Preset")
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension InventoryPresetOption.Source {
    static let allSourcesOrdered: [Self] = [.custom, .local, .cloud, .builtin]
}

/// Pick an empty-spool type from the spool weight catalog.
struct InventoryCatalogWeightPicker: View {
    @Environment(InventoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var selectedId: Int?
    let onSelect: (InventorySpoolCatalogEntry?) -> Void
    @State private var search = ""

    var body: some View {
        let q = search.lowercased()
        let list = store.spoolCatalog.filter { q.isEmpty || $0.name.lowercased().contains(q) }
        List {
            Button("Custom Weight") { onSelect(nil); dismiss() }
            ForEach(list) { entry in
                Button {
                    onSelect(entry)
                    dismiss()
                } label: {
                    HStack {
                        Text(entry.name).foregroundStyle(.primary)
                        Spacer()
                        Text("\(entry.weight) g").foregroundStyle(.secondary).monospacedDigit()
                        if entry.id == selectedId { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                    }
                }
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
        .navigationTitle("Empty Spool Type")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Pick a color from the catalog entries that match the spool's brand/material.
struct InventoryCatalogColorPicker: View {
    @Environment(\.dismiss) private var dismiss
    let colors: [InventoryColorEntry]
    let onSelect: (InventoryColorEntry) -> Void
    @State private var search = ""

    var body: some View {
        let q = search.lowercased()
        let list = colors.filter { q.isEmpty || $0.colorName.lowercased().contains(q) || ($0.material ?? "").lowercased().contains(q) }
        List(list) { entry in
            Button {
                onSelect(entry)
                dismiss()
            } label: {
                HStack(spacing: 12) {
                    InventorySpoolSwatch(rgba: InventoryColors.normalizedRGBA(entry.hexColor), extraColors: entry.extraColors, effectType: entry.effectType, size: 28)
                    VStack(alignment: .leading) {
                        Text(entry.colorName).foregroundStyle(.primary)
                        Text(InventoryFormat.joined([entry.manufacturer, entry.material, entry.hexColor])).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
        .navigationTitle("Catalog Colors")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Choose a pressure-advance (K) calibration stored on a printer.
struct InventoryKProfilePicker: View {
    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var printers
    @Environment(\.dismiss) private var dismiss
    let onPick: (InventoryKProfileInput) -> Void

    @State private var printerId: Int?
    @State private var diameter = "0.4"
    @State private var loader = Loader<[InventoryPrinterKProfile]>()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Printer", selection: $printerId) {
                        Text("Choose…").tag(Int?.none)
                        ForEach(printers.printers) { Text($0.name).tag(Int?.some($0.id)) }
                    }
                    Picker("Nozzle", selection: $diameter) {
                        ForEach(InventoryFormOptions.nozzleDiameters, id: \.self) { Text("\($0) mm").tag($0) }
                    }
                } footer: {
                    Text("Calibrations are read live from the printer, which must be online.")
                }
                if printerId != nil {
                    Section("Calibrations") {
                        if let profiles = loader.value {
                            if profiles.isEmpty {
                                Text("No calibrations for this nozzle.").foregroundStyle(.secondary)
                            }
                            ForEach(profiles, id: \.self) { p in
                                Button {
                                    guard let printerId else { return }
                                    let flow = String((p.nozzleId ?? "").uppercased().prefix(2))
                                    onPick(InventoryKProfileInput(printerId: printerId, extruder: p.extruderId ?? 0, nozzleDiameter: p.nozzleDiameter,
                                                                  nozzleType: flow == "HH" || flow == "HS" ? flow : nil, kValue: Double(p.kValue) ?? 0,
                                                                  name: p.name, caliIdx: p.slotId, settingId: (p.settingId ?? "").isEmpty ? nil : p.settingId))
                                    dismiss()
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text(p.name).foregroundStyle(.primary)
                                            Text(InventoryFormat.joined([p.filamentId, (p.extruderId ?? 0) == 1 ? "Left nozzle" : nil])).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text("K \(p.kValue)").monospacedDigit().foregroundStyle(.secondary)
                                    }
                                }
                            }
                        } else if let error = loader.error {
                            Text(error).foregroundStyle(.secondary)
                        } else {
                            ProgressView()
                        }
                    }
                }
            }
            .navigationTitle("Pressure Advance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task(id: "\(printerId ?? -1)-\(diameter)") {
                guard let printerId else { return }
                loader.value = nil
                await loader.load {
                    try await session.client.get("printers/\(printerId)/kprofiles/", query: ["nozzle_diameter": .string(diameter)], as: InventoryPrinterKProfiles.self).profiles
                }
            }
        }
    }
}

/// Choose a slicer preset override for one printer model + nozzle size.
struct InventoryModelPresetPicker: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let options: [InventoryPresetOption]
    let onPick: (InventoryFilamentPresetInput) -> Void

    @State private var models: [String] = []
    @State private var model = ""
    @State private var diameter = "0.4"
    @State private var preset: InventoryPresetOption?

    var body: some View {
        NavigationStack {
            Form {
                Picker("Printer Model", selection: $model) {
                    Text("Choose…").tag("")
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
                Picker("Nozzle", selection: $diameter) {
                    ForEach(InventoryFormOptions.nozzleDiameters, id: \.self) { Text("\($0) mm").tag($0) }
                }
                NavigationLink {
                    InventoryPresetPickerView(options: options, selectedCode: preset?.code) { preset = $0 }
                } label: {
                    LabeledContent("Preset", value: preset?.name ?? "Choose…")
                }
            }
            .navigationTitle("Per-Printer Preset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let preset, !model.isEmpty else { return }
                        onPick(InventoryFilamentPresetInput(printerModel: model, nozzleDiameter: diameter, slicerFilament: preset.code, slicerFilamentName: preset.name))
                        dismiss()
                    }
                    .disabled(model.isEmpty || preset == nil)
                }
            }
            .task {
                let map = (try? await session.client.get("slicer/printer-models", as: [String: String].self)) ?? [:]
                models = Array(Set(map.values)).sorted()
            }
        }
    }
}
