import SwiftUI

// MARK: - Storage locations

struct InventoryLocationsView: View {
    @Environment(AppSession.self) private var session
    @Environment(InventoryStore.self) private var store
    @Environment(LiveUpdates.self) private var live

    @State private var editing: InventoryLocationEditTarget?
    @State private var deleting: InventoryLocation?
    @State private var runner = ActionRunner()

    private var canEdit: Bool { session.can("inventory:update") }

    var body: some View {
        List {
            ForEach(store.locations) { loc in
                NavigationLink {
                    InventoryLocationSpoolsView(location: loc)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(loc.name)
                            if let id = loc.identifier, !id.isEmpty { Text(id).font(.caption.monospaced()).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Text("\(loc.spoolCount ?? 0)").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    if canEdit {
                        Button(role: .destructive) { deleting = loc } label: { Label("Delete", systemImage: "trash") }
                            .disabled((loc.spoolCount ?? 0) > 0)
                        Button { editing = .edit(loc) } label: { Label("Edit", systemImage: "pencil") }
                    }
                }
                .contextMenu {
                    if canEdit {
                        Button { editing = .edit(loc) } label: { Label("Edit", systemImage: "pencil") }
                        Button(role: .destructive) { deleting = loc } label: { Label("Delete", systemImage: "trash") }
                            .disabled((loc.spoolCount ?? 0) > 0)
                    }
                }
            }
        }
        .overlay {
            if store.locations.isEmpty {
                ContentUnavailableView {
                    Label("No Storage Locations", systemImage: "mappin.and.ellipse")
                } description: {
                    Text("Locations such as shelves or dry boxes help you find spools.")
                } actions: {
                    if canEdit { Button("Add Location") { editing = .new }.buttonStyle(.borderedProminent) }
                }
            }
        }
        .navigationTitle("Storage Locations")
        .toolbar {
            if canEdit {
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = .new } label: { Label("Add Location", systemImage: "plus") }
                }
            }
        }
        .task(id: live.revision("inventory_changed")) { await store.reloadLocations() }
        .refreshable { await store.reloadLocations() }
        .sheet(item: $editing) { InventoryLocationEditor(target: $0) }
        .confirmationDialog("Delete \(deleting?.name ?? "location")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting) { loc in
            Button("Delete", role: .destructive) { Task { await runner.run("Location deleted") { try await store.deleteLocation(loc.id) } } }
        } message: { loc in
            Text((loc.spoolCount ?? 0) > 0 ? "Move its spools elsewhere first." : "This can't be undone.")
        }
        .actionAlerts(runner)
    }
}

enum InventoryLocationEditTarget: Identifiable {
    case new
    case edit(InventoryLocation)
    var id: String {
        switch self {
        case .new: "new"
        case .edit(let l): "edit-\(l.id)"
        }
    }
}

private struct InventoryLocationEditor: View {
    @Environment(InventoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let target: InventoryLocationEditTarget
    @State private var name = ""
    @State private var identifier = ""
    @State private var runner = ActionRunner()

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("Identifier (optional)", text: $identifier)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            }
            .navigationTitle({ if case .new = target { return "New Location" } else { return "Edit Location" } }())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let n = name.trimmingCharacters(in: .whitespaces)
                        let i = identifier.trimmingCharacters(in: .whitespaces)
                        Task {
                            await runner.run {
                                switch target {
                                case .new: _ = try await store.createLocation(name: n, identifier: i)
                                case .edit(let loc): try await store.updateLocation(loc.id, name: n, identifier: i)
                                }
                            }
                            if runner.errorMessage == nil { dismiss() }
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || runner.isRunning)
                }
            }
            .onAppear {
                if case .edit(let loc) = target { name = loc.name; identifier = loc.identifier ?? "" }
            }
            .actionAlerts(runner)
        }
        .presentationDetents([.medium])
    }
}

private struct InventoryLocationSpoolsView: View {
    @Environment(InventoryStore.self) private var store
    let location: InventoryLocation

    var body: some View {
        let spools = store.spools.filter { s in
            if let id = s.locationId { return id == location.id }
            return (s.storageLocation ?? "").trimmingCharacters(in: .whitespaces).lowercased() == location.name.lowercased()
        }
        List(spools) { spool in
            NavigationLink(value: InventoryRoute.spool(spool.id)) {
                InventorySpoolRow(spool: spool, slot: store.slot(for: spool.id), lowStockThreshold: store.lowStockThreshold)
            }
        }
        .overlay { if spools.isEmpty { ContentUnavailableView("No Spools Here", systemImage: "shippingbox") } }
        .navigationTitle(location.name)
    }
}

// MARK: - Empty spool weights

struct InventorySpoolCatalogView: View {
    @Environment(AppSession.self) private var session
    @Environment(InventoryStore.self) private var store
    @State private var search = ""
    @State private var editing: InventorySpoolCatalogEntry?
    @State private var adding = false
    @State private var confirmReset = false
    @State private var runner = ActionRunner()

    private var canEdit: Bool { session.can("inventory:update") }

    var body: some View {
        let q = search.lowercased()
        let list = store.spoolCatalog.filter { q.isEmpty || $0.name.lowercased().contains(q) }
        List {
            ForEach(list) { entry in
                HStack {
                    Text(entry.name)
                    if entry.isDefault == false { StatusBadge(text: "Custom", color: .accentColor) }
                    Spacer()
                    Text("\(entry.weight) g").monospacedDigit().foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { if canEdit { editing = entry } }
                .swipeActions {
                    if canEdit {
                        Button(role: .destructive) {
                            Task { await runner.run { try await store.client.call(.delete, "inventory/catalog/\(entry.id)"); await store.reloadCatalog() } }
                        } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
        }
        .searchable(text: $search)
        .overlay { if list.isEmpty { ContentUnavailableView("No Entries", systemImage: "scalemass") } }
        .navigationTitle("Empty Spool Weights")
        .toolbar {
            if canEdit {
                ToolbarItem(placement: .primaryAction) { Button { adding = true } label: { Label("Add", systemImage: "plus") } }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Reset to Defaults", role: .destructive) { confirmReset = true }
                }
            }
        }
        .task { await store.reloadCatalog() }
        .refreshable { await store.reloadCatalog() }
        .sheet(item: $editing) { InventoryWeightEntryEditor(entry: $0) }
        .sheet(isPresented: $adding) { InventoryWeightEntryEditor(entry: nil) }
        .confirm("Reset the spool weight catalog?", isPresented: $confirmReset, message: "Custom entries are removed and the built-in list is restored.", action: "Reset") {
            Task { await runner.run("Catalog reset") { try await store.client.call(.post, "inventory/catalog/reset"); await store.reloadCatalog() } }
        }
        .actionAlerts(runner)
    }
}

private struct InventoryWeightEntryEditor: View {
    @Environment(InventoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let entry: InventorySpoolCatalogEntry?
    @State private var name = ""
    @State private var weight: Int?
    @State private var runner = ActionRunner()

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name (e.g. Brand - Plastic)", text: $name)
                LabeledContent("Empty Weight") {
                    TextField("g", value: $weight, format: .number).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                }
            }
            .navigationTitle(entry == nil ? "New Spool Type" : "Edit Spool Type")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let weight else { return }
                        let body: JSONValue = ["name": .string(name.trimmingCharacters(in: .whitespaces)), "weight": .number(Double(weight))]
                        Task {
                            await runner.run {
                                if let entry {
                                    try await store.client.call(.put, "inventory/catalog/\(entry.id)", body: body)
                                } else {
                                    try await store.client.call(.post, "inventory/catalog", body: body)
                                }
                                await store.reloadCatalog()
                            }
                            if runner.errorMessage == nil { dismiss() }
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || (weight ?? -1) < 0 || runner.isRunning)
                }
            }
            .onAppear { if let entry { name = entry.name; weight = entry.weight } }
            .actionAlerts(runner)
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Color catalog

struct InventoryColorCatalogView: View {
    @Environment(AppSession.self) private var session
    @Environment(InventoryStore.self) private var store
    @State private var loader = Loader<[InventoryColorEntry]>()
    @State private var search = ""
    @State private var editing: InventoryColorEntry?
    @State private var adding = false
    @State private var confirmReset = false
    @State private var confirmSync = false
    @State private var runner = ActionRunner()

    private var canEdit: Bool { session.can("inventory:update") }

    var body: some View {
        LoadingContent(loader: loader, retry: load) { colors in
            let q = search.lowercased()
            let list = colors.filter { q.isEmpty || $0.manufacturer.lowercased().contains(q) || $0.colorName.lowercased().contains(q) || ($0.material ?? "").lowercased().contains(q) || $0.hexColor.lowercased().contains(q) }
            let brands = Dictionary(grouping: list, by: \.manufacturer).sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            List {
                ForEach(brands, id: \.key) { brand, entries in
                    Section("\(brand) (\(entries.count))") {
                        ForEach(entries) { entry in
                            HStack(spacing: 12) {
                                InventorySpoolSwatch(rgba: InventoryColors.normalizedRGBA(entry.hexColor), extraColors: entry.extraColors, effectType: entry.effectType, size: 26)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.colorName)
                                    Text(InventoryFormat.joined([entry.material, entry.hexColor])).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if entry.isDefault == false { StatusBadge(text: "Custom", color: .accentColor) }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { if canEdit { editing = entry } }
                            .swipeActions {
                                if canEdit {
                                    Button(role: .destructive) {
                                        Task { await runner.run { try await store.client.call(.delete, "inventory/colors/\(entry.id)") }; await load() }
                                    } label: { Label("Delete", systemImage: "trash") }
                                }
                            }
                        }
                    }
                }
            }
            .overlay { if list.isEmpty { ContentUnavailableView.search(text: search) } }
        }
        .searchable(text: $search, prompt: "Brand, color, material or hex")
        .navigationTitle("Color Catalog")
        .toolbar {
            if canEdit {
                ToolbarItem(placement: .primaryAction) { Button { adding = true } label: { Label("Add", systemImage: "plus") } }
                ToolbarItem(placement: .secondaryAction) {
                    Menu {
                        Button { confirmSync = true } label: { Label("Sync from Online Database", systemImage: "arrow.triangle.2.circlepath") }
                        Button(role: .destructive) { confirmReset = true } label: { Label("Reset to Defaults", systemImage: "arrow.counterclockwise") }
                    } label: { Label("More", systemImage: "ellipsis.circle") }
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $editing) { entry in InventoryColorEntryEditor(entry: entry) { await load() } }
        .sheet(isPresented: $adding) { InventoryColorEntryEditor(entry: nil) { await load() } }
        .confirm("Reset the color catalog?", isPresented: $confirmReset, message: "Custom colors are removed and the built-in catalog is restored.", action: "Reset") {
            Task { await runner.run("Catalog reset") { try await store.client.call(.post, "inventory/colors/reset") }; await load() }
        }
        .confirm("Sync colors from the online database?", isPresented: $confirmSync, message: "Downloads the latest manufacturer colors. This can take a minute.", action: "Sync", role: nil) {
            Task {
                await runner.run("Color catalog synced") { _ = try await store.client.rawData(store.client.makeRequest(.post, "inventory/colors/sync")) }
                await load()
            }
        }
        .overlay { if runner.isRunning { ProgressView().controlSize(.large) } }
        .actionAlerts(runner)
    }

    private func load() async {
        await loader.load { try await store.client.get("inventory/colors") }
    }
}

private struct InventoryColorEntryEditor: View {
    @Environment(InventoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let entry: InventoryColorEntry?
    let onSaved: () async -> Void

    @State private var manufacturer = ""
    @State private var colorName = ""
    @State private var hex = "#808080"
    @State private var material = ""
    @State private var extraColors = ""
    @State private var effect = ""
    @State private var runner = ActionRunner()

    var body: some View {
        NavigationStack {
            Form {
                InventorySuggestField(title: "Manufacturer", text: $manufacturer, suggestions: InventoryFormOptions.brands)
                TextField("Color name", text: $colorName)
                HStack {
                    TextField("Hex", text: $hex).font(.body.monospaced()).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    ColorPicker("", selection: Binding(get: { InventoryColors.color(hex) ?? .gray }, set: { hex = "#" + String(InventoryColors.rgba(from: $0).prefix(6)) }), supportsOpacity: false)
                        .labelsHidden()
                }
                InventorySuggestField(title: "Material (optional)", text: $material, suggestions: InventoryFormOptions.materials, capitalization: .characters)
                TextField("Gradient stops (optional)", text: $extraColors).font(.body.monospaced()).textInputAutocapitalization(.characters)
                Picker("Effect", selection: $effect) {
                    Text("None").tag("")
                    ForEach(InventoryFormOptions.effects, id: \.self) { Text($0.capitalized).tag($0) }
                }
            }
            .navigationTitle(entry == nil ? "New Color" : "Edit Color")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(manufacturer.isEmpty || colorName.isEmpty || InventoryColors.normalizedRGBA(hex) == nil || runner.isRunning)
                }
            }
            .onAppear {
                if let entry {
                    manufacturer = entry.manufacturer; colorName = entry.colorName; hex = entry.hexColor
                    material = entry.material ?? ""; extraColors = entry.extraColors ?? ""; effect = entry.effectType ?? ""
                }
            }
            .actionAlerts(runner)
        }
    }

    private func save() {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if !h.hasPrefix("#") { h = "#" + h }
        func opt(_ s: String) -> JSONValue { let t = s.trimmingCharacters(in: .whitespaces); return t.isEmpty ? .null : .string(t) }
        let body: JSONValue = [
            "manufacturer": .string(manufacturer.trimmingCharacters(in: .whitespaces)),
            "color_name": .string(colorName.trimmingCharacters(in: .whitespaces)),
            "hex_color": .string(h.uppercased()),
            "material": opt(material),
            "extra_colors": opt(extraColors),
            "effect_type": opt(effect),
        ]
        Task {
            await runner.run {
                if let entry {
                    try await store.client.call(.put, "inventory/colors/\(entry.id)", body: body)
                } else {
                    try await store.client.call(.post, "inventory/colors", body: body)
                }
            }
            if runner.errorMessage == nil {
                await onSaved()
                dismiss()
            }
        }
    }
}

// MARK: - Filament types (cost catalog)

struct InventoryFilamentCatalogView: View {
    @Environment(AppSession.self) private var session
    @Environment(InventoryStore.self) private var store
    @State private var loader = Loader<[InventoryFilamentType]>()
    @State private var search = ""
    @State private var editing: InventoryFilamentType?
    @State private var adding = false
    @State private var deleting: InventoryFilamentType?
    @State private var confirmSeed = false
    @State private var runner = ActionRunner()

    var body: some View {
        LoadingContent(loader: loader, retry: load) { filaments in
            let q = search.lowercased()
            let list = filaments.filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.type.lowercased().contains(q) || ($0.brand ?? "").lowercased().contains(q) }
            let groups = Dictionary(grouping: list, by: \.type).sorted { $0.key < $1.key }
            List {
                ForEach(groups, id: \.key) { type, items in
                    Section(type) {
                        ForEach(items) { f in
                            NavigationLink {
                                InventoryFilamentTypeDetail(filament: f)
                            } label: {
                                HStack(spacing: 12) {
                                    InventorySpoolSwatch(rgba: f.colorHex.flatMap(InventoryColors.normalizedRGBA), size: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(f.name)
                                        Text(InventoryFormat.joined([f.brand, f.color])).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if let cost = f.costPerKg { Text("\(Fmt.currency(cost, code: f.currency ?? store.currencyCode))/kg").font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                            .swipeActions {
                                if session.can("filaments:delete") {
                                    Button(role: .destructive) { deleting = f } label: { Label("Delete", systemImage: "trash") }
                                }
                                if session.can("filaments:update") {
                                    Button { editing = f } label: { Label("Edit", systemImage: "pencil") }
                                }
                            }
                        }
                    }
                }
            }
            .overlay {
                if filaments.isEmpty {
                    ContentUnavailableView {
                        Label("No Filament Types", systemImage: "list.bullet.rectangle")
                    } description: {
                        Text("Filament types record cost per kg and print temperatures for cost tracking.")
                    } actions: {
                        if session.can("filaments:create") {
                            Button("Add Default Types") { confirmSeed = true }.buttonStyle(.borderedProminent)
                        }
                    }
                } else if list.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
        }
        .searchable(text: $search)
        .navigationTitle("Filament Types")
        .toolbar {
            if session.can("filaments:create") {
                ToolbarItem(placement: .primaryAction) { Button { adding = true } label: { Label("Add", systemImage: "plus") } }
                ToolbarItem(placement: .secondaryAction) { Button("Add Default Types") { confirmSeed = true } }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $editing) { f in InventoryFilamentTypeEditor(filament: f) { await load() } }
        .sheet(isPresented: $adding) { InventoryFilamentTypeEditor(filament: nil) { await load() } }
        .confirm("Add default filament types?", isPresented: $confirmSeed, message: "Common filament types with typical costs are added. Existing entries are kept.", action: "Add", role: nil) {
            Task { await runner.run("Defaults added") { try await store.client.call(.post, "filament-catalog/seed-defaults") }; await load() }
        }
        .confirmationDialog("Delete \(deleting?.name ?? "filament")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting) { f in
            Button("Delete", role: .destructive) {
                Task { await runner.run("Deleted") { try await store.client.call(.delete, "filament-catalog/\(f.id)") }; await load() }
            }
        }
        .actionAlerts(runner)
    }

    private func load() async {
        await loader.load { try await store.client.get("filament-catalog/") }
    }
}

private struct InventoryFilamentTypeDetail: View {
    @Environment(InventoryStore.self) private var store
    let filament: InventoryFilamentType
    @State private var grams: Double = 100
    @State private var cost: InventoryFilamentCost?
    @State private var runner = ActionRunner()

    var body: some View {
        let f = filament
        Form {
            Section("Filament") {
                InfoRow("Name", f.name)
                InfoRow("Type", f.type)
                InfoRow("Brand", f.brand)
                LabeledContent("Color") {
                    HStack {
                        Text(InventoryFormat.joined([f.color, f.colorHex]))
                        if let hex = f.colorHex { InventorySpoolSwatch(rgba: InventoryColors.normalizedRGBA(hex), size: 20) }
                    }
                }
                InfoRow("Density", f.density.map { "\(Fmt.number($0, digits: 2)) g/cm³" })
            }
            Section("Cost") {
                InfoRow("Cost per kg", f.costPerKg.map { Fmt.currency($0, code: f.currency ?? store.currencyCode) })
                InfoRow("Spool Weight", f.spoolWeightG.map { InventoryFormat.grams($0) })
            }
            Section("Temperatures") {
                InfoRow("Nozzle", range(f.printTempMin, f.printTempMax))
                InfoRow("Bed", range(f.bedTempMin, f.bedTempMax))
            }
            Section {
                LabeledContent("Weight") {
                    TextField("g", value: $grams, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                }
                Button("Calculate Cost") {
                    Task {
                        await runner.run {
                            cost = try await store.client.send(.post, "filament-catalog/calculate-cost", query: ["filament_id": .int(f.id), "weight_grams": .double(grams)])
                        }
                    }
                }
                if let cost { InfoRow("Cost", Fmt.currency(cost.cost, code: cost.currency)) }
            } header: {
                Text("Cost Calculator")
            }
        }
        .navigationTitle(f.name)
        .navigationBarTitleDisplayMode(.inline)
        .actionAlerts(runner)
    }

    private func range(_ a: Int?, _ b: Int?) -> String? {
        guard a != nil || b != nil else { return nil }
        return "\(a.map(String.init) ?? "?")–\(b.map(String.init) ?? "?") °C"
    }
}

private struct InventoryFilamentTypeEditor: View {
    @Environment(InventoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let filament: InventoryFilamentType?
    let onSaved: () async -> Void

    @State private var name = ""
    @State private var type = "PLA"
    @State private var brand = ""
    @State private var color = ""
    @State private var colorHex = ""
    @State private var costPerKg: Double? = 25
    @State private var spoolWeight: Double? = 1000
    @State private var currency = "USD"
    @State private var density: Double?
    @State private var printMin: Int?
    @State private var printMax: Int?
    @State private var bedMin: Int?
    @State private var bedMax: Int?
    @State private var runner = ActionRunner()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    InventorySuggestField(title: "Type", text: $type, suggestions: InventoryFormOptions.materials, capitalization: .characters)
                    InventorySuggestField(title: "Brand", text: $brand, suggestions: InventoryFormOptions.brands)
                    TextField("Color", text: $color)
                    TextField("Color hex (optional)", text: $colorHex).font(.body.monospaced()).textInputAutocapitalization(.characters)
                }
                Section("Cost") {
                    numberRow("Cost per kg", $costPerKg)
                    TextField("Currency", text: $currency).textInputAutocapitalization(.characters)
                    numberRow("Spool weight (g)", $spoolWeight)
                    numberRow("Density (g/cm³)", $density)
                }
                Section("Temperatures (°C)") {
                    intRow("Nozzle min", $printMin)
                    intRow("Nozzle max", $printMax)
                    intRow("Bed min", $bedMin)
                    intRow("Bed max", $bedMax)
                }
            }
            .navigationTitle(filament == nil ? "New Filament Type" : "Edit Filament Type")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(name.isEmpty || type.isEmpty || runner.isRunning)
                }
            }
            .onAppear {
                guard let f = filament else { currency = store.currencyCode; return }
                name = f.name; type = f.type; brand = f.brand ?? ""; color = f.color ?? ""; colorHex = f.colorHex ?? ""
                costPerKg = f.costPerKg; spoolWeight = f.spoolWeightG; currency = f.currency ?? "USD"; density = f.density
                printMin = f.printTempMin; printMax = f.printTempMax; bedMin = f.bedTempMin; bedMax = f.bedTempMax
            }
            .actionAlerts(runner)
        }
    }

    private func numberRow(_ title: String, _ value: Binding<Double?>) -> some View {
        LabeledContent(title) {
            TextField("—", value: value, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
        }
    }

    private func intRow(_ title: String, _ value: Binding<Int?>) -> some View {
        LabeledContent(title) {
            TextField("—", value: value, format: .number).keyboardType(.numberPad).multilineTextAlignment(.trailing)
        }
    }

    private func save() {
        func opt(_ s: String) -> JSONValue { let t = s.trimmingCharacters(in: .whitespaces); return t.isEmpty ? .null : .string(t) }
        func num(_ d: Double?) -> JSONValue { d.map { .number($0) } ?? .null }
        func int(_ i: Int?) -> JSONValue { i.map { .number(Double($0)) } ?? .null }
        var body: [String: JSONValue] = [
            "name": .string(name), "type": .string(type), "brand": opt(brand), "color": opt(color), "color_hex": opt(colorHex),
            "currency": .string(currency.isEmpty ? "USD" : currency.uppercased()), "density": num(density),
            "print_temp_min": int(printMin), "print_temp_max": int(printMax), "bed_temp_min": int(bedMin), "bed_temp_max": int(bedMax),
        ]
        if let costPerKg { body["cost_per_kg"] = .number(costPerKg) }
        if let spoolWeight { body["spool_weight_g"] = .number(spoolWeight) }
        Task {
            await runner.run {
                if let filament {
                    try await store.client.call(.patch, "filament-catalog/\(filament.id)", body: JSONValue.object(body))
                } else {
                    try await store.client.call(.post, "filament-catalog/", body: JSONValue.object(body))
                }
            }
            if runner.errorMessage == nil {
                await onSaved()
                dismiss()
            }
        }
    }
}

// MARK: - Usage log

/// Recent filament consumption across all spools.
struct InventoryUsageLogView: View {
    @Environment(InventoryStore.self) private var store
    @Environment(PrinterStore.self) private var printers
    @Environment(LiveUpdates.self) private var live
    @State private var loader = Loader<[InventoryUsageRecord]>()
    @State private var printerId: Int?

    var body: some View {
        LoadingContent(loader: loader, retry: load) { records in
            List {
                if records.isEmpty {
                    ContentUnavailableView("No Usage Yet", systemImage: "clock.arrow.circlepath", description: Text("Filament used by prints appears here."))
                } else {
                    Section {
                        LabeledContent("Total", value: InventoryFormat.grams(records.reduce(0) { $0 + $1.weightUsed }))
                        let cost = records.compactMap(\.cost).reduce(0, +)
                        if cost > 0 {
                            LabeledContent("Cost", value: Fmt.currency(cost, code: store.currencyCode))
                        }
                    }
                    Section("Prints") {
                        ForEach(records) { r in
                            NavigationLink(value: InventoryRoute.spool(r.spoolId)) {
                                HStack(spacing: 12) {
                                    let spool = store.spool(r.spoolId)
                                    InventorySpoolSwatch(rgba: spool?.rgba, extraColors: spool?.extraColors, size: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(r.printName ?? "Print").lineLimit(1)
                                        Text(InventoryFormat.joined([spool.map { "#\($0.id) \($0.materialLine)" } ?? "Spool #\(r.spoolId)", r.printerId.flatMap { printers.printer($0)?.name }, Fmt.date(r.createdAt)]))
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(InventoryFormat.grams(r.weightUsed)).monospacedDigit()
                                        if let status = r.status, status != "completed" {
                                            Text(status.capitalized).font(.caption2).foregroundStyle(status == "failed" ? .red : .orange)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Usage Log")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Printer", selection: $printerId) {
                        Text("All Printers").tag(Int?.none)
                        ForEach(printers.printers) { Text($0.name).tag(Int?.some($0.id)) }
                    }
                } label: {
                    Label("Printer", systemImage: printerId == nil ? "printer" : "printer.fill")
                }
            }
        }
        .task(id: "\(printerId ?? -1)-\(live.revision("spool_usage_logged"))") { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        let pid = printerId
        await loader.load { try await store.client.get("inventory/usage", query: ["limit": 300, "printer_id": .of(pid)]) }
    }
}
