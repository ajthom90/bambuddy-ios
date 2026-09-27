import SwiftUI

// MARK: - Setup tab (types + per-printer intervals)

struct MaintenanceSetupView: View {
    @Environment(AppSession.self) private var session
    let store: MaintenanceStore
    let reload: () async -> Void

    @State private var runner = ActionRunner()
    @State private var showAddType = false
    @State private var confirmRestore = false
    @State private var editingInterval: MaintenanceItemStatus?

    var body: some View {
        let system = store.types.filter(\.isSystem).sorted { $0.name < $1.name }
        let custom = store.types.filter { !$0.isSystem }.sorted { $0.name < $1.name }
        List {
            Section {
                ForEach(system) { typeRow($0) }
            } header: {
                Text("Built-in Types")
            } footer: {
                Text("Built-in tasks are added to every printer they apply to. Deleted ones can be brought back with Restore Defaults.")
            }

            Section {
                if custom.isEmpty {
                    Text("Add your own tasks, like replacing a filter every month.").foregroundStyle(.secondary)
                }
                ForEach(custom) { typeRow($0) }
                if session.can("maintenance:create") {
                    Button { showAddType = true } label: { Label("Add Custom Type…", systemImage: "plus.circle") }
                }
            } header: {
                Text("Custom Types")
            }

            ForEach(store.overview ?? []) { printer in
                Section {
                    ForEach(printer.maintenanceItems.sorted { $0.maintenanceTypeId < $1.maintenanceTypeId }) { item in
                        Button {
                            if session.can("maintenance:update") { editingInterval = item }
                        } label: {
                            HStack {
                                Label(item.maintenanceTypeName, systemImage: MaintenanceIcons.symbol(for: item.maintenanceTypeIcon))
                                    .foregroundStyle(item.enabled ? .primary : .secondary)
                                Spacer()
                                Label(MaintenanceFormat.shortInterval(item.intervalHours, type: item.intervalType),
                                      systemImage: item.isDaysBased ? "calendar" : "timer")
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(isOverridden(item) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            }
                        }
                    }
                } header: {
                    Text("Intervals · \(printer.printerName)")
                } footer: {
                    if printer.maintenanceItems.contains(where: isOverridden) {
                        Text("Highlighted intervals differ from the type's default.")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Menu {
                    if session.can("maintenance:create") {
                        Button { showAddType = true } label: { Label("Add Custom Type", systemImage: "plus") }
                    }
                    if session.can("maintenance:delete") {
                        Button { confirmRestore = true } label: { Label("Restore Default Types", systemImage: "arrow.counterclockwise") }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showAddType) {
            MaintenanceTypeEditor(existing: nil, printers: store.overview ?? []) { Task { await reload() } }
        }
        .sheet(item: $editingInterval) { item in
            MaintenanceIntervalEditor(item: item, type: store.type(item.maintenanceTypeId)) { Task { await reload() } }
        }
        .confirm("Restore Default Types?", isPresented: $confirmRestore,
                 message: "Built-in maintenance types you deleted will be added back to your printers.", action: "Restore", role: nil) {
            Task { await restoreDefaults() }
        }
        .actionAlerts(runner)
    }

    private func isOverridden(_ item: MaintenanceItemStatus) -> Bool {
        guard let type = store.type(item.maintenanceTypeId) else { return false }
        return abs(type.interval - item.intervalHours) >= 0.01 || type.kind != item.intervalType
    }

    private func typeRow(_ type: MaintenanceTypeInfo) -> some View {
        NavigationLink(value: MaintenanceRoute.type(type.id)) {
            HStack(spacing: 12) {
                Image(systemName: MaintenanceIcons.symbol(for: type.icon))
                    .foregroundStyle(type.isSystem ? Color.secondary : Color.accentColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(type.name)
                    Text(MaintenanceFormat.interval(type.interval, type: type.kind)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !type.isSystem {
                    let count = store.assignments(for: type.id).count
                    Label("\(count)", systemImage: "printer")
                        .font(.caption)
                        .foregroundStyle(count == 0 ? .orange : .secondary)
                }
            }
        }
    }

    private func restoreDefaults() async {
        await runner.run(nil) {
            let result: MaintenanceRestoreResult = try await session.client.send(.post, "maintenance/types/restore-defaults")
            let n = result.restored ?? 0
            runner.successMessage = n == 0 ? "Nothing to restore" : "Restored \(n) type\(n == 1 ? "" : "s")"
        }
        await reload()
    }
}

// MARK: - Type detail

struct MaintenanceTypeDetailView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let store: MaintenanceStore
    let typeId: Int
    let reload: () async -> Void

    @State private var runner = ActionRunner()
    @State private var editing = false
    @State private var confirmDelete = false

    var body: some View {
        Group {
            if let type = store.type(typeId) {
                content(type)
            } else {
                ContentUnavailableView("Type Not Found", systemImage: "wrench.adjustable")
            }
        }
        .navigationTitle(store.type(typeId)?.name ?? "Maintenance Type")
        .navigationBarTitleDisplayMode(.inline)
        .actionAlerts(runner)
    }

    private func content(_ type: MaintenanceTypeInfo) -> some View {
        let assigned = store.assignments(for: type.id)
        return List {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: MaintenanceIcons.symbol(for: type.icon))
                        .font(.title2).foregroundStyle(.tint)
                        .frame(width: 52, height: 52)
                        .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(type.name).font(.headline)
                        StatusBadge(text: type.isSystem ? "Built-in" : "Custom", color: type.isSystem ? .secondary : .accentColor)
                    }
                }
                if let d = type.description, !d.isEmpty { Text(d).foregroundStyle(.secondary) }
                InfoRow("Default interval", MaintenanceFormat.interval(type.interval, type: type.kind))
                if let s = type.wikiUrl, let url = URL(string: s) {
                    Link(destination: url) { Label("View Guide", systemImage: "book") }
                }
            }

            if type.isSystem {
                Section {
                    if assigned.isEmpty { Text("Not tracked on any printer.").foregroundStyle(.secondary) }
                    ForEach(assigned, id: \.itemId) { a in
                        NavigationLink(value: MaintenanceRoute.item(printerId: a.printer.printerId, itemId: a.itemId)) {
                            Text(a.printer.printerName)
                        }
                    }
                } header: {
                    Text("Printers")
                } footer: {
                    Text("Built-in tasks apply automatically to every printer model they fit.")
                }
            } else {
                Section {
                    let printers = store.overview ?? []
                    if printers.isEmpty { Text("No printers.").foregroundStyle(.secondary) }
                    ForEach(printers) { printer in
                        let itemId = assigned.first { $0.printer.printerId == printer.printerId }?.itemId
                        Toggle(printer.printerName, isOn: Binding(
                            get: { itemId != nil },
                            set: { on in Task { await setAssigned(on, printer: printer, itemId: itemId, type: type) } }
                        ))
                        .disabled(itemId == nil ? !session.can("maintenance:create") : !session.can("maintenance:delete"))
                    }
                } header: {
                    Text("Assigned Printers")
                } footer: {
                    if assigned.isEmpty { Text("Assign at least one printer to track this task.").foregroundStyle(.orange) }
                }
            }

            Section {
                if !type.isSystem, session.can("maintenance:update") {
                    Button { editing = true } label: { Label("Edit Type…", systemImage: "pencil") }
                }
                if session.can("maintenance:delete") {
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete Type", systemImage: "trash") }
                }
            }
        }
        .sheet(isPresented: $editing) {
            MaintenanceTypeEditor(existing: type, printers: []) { Task { await reload() } }
        }
        .confirm("Delete “\(type.name)”?", isPresented: $confirmDelete,
                 message: type.isSystem
                    ? "This built-in task will be hidden from every printer. You can bring it back with Restore Default Types."
                    : "This custom task and its history will be removed from all printers.") {
            Task { await delete(type) }
        }
    }

    private func setAssigned(_ on: Bool, printer: MaintenancePrinterOverview, itemId: Int?, type: MaintenanceTypeInfo) async {
        await runner.run(on ? "Assigned to \(printer.printerName)" : "Removed from \(printer.printerName)") {
            if on {
                let _: MaintenanceItemRecord = try await session.client.send(.post, "maintenance/printers/\(printer.printerId)/assign/\(type.id)")
            } else if let itemId {
                try await session.client.call(.delete, "maintenance/items/\(itemId)")
            }
        }
        await reload()
    }

    private func delete(_ type: MaintenanceTypeInfo) async {
        await runner.run(nil) {
            try await session.client.call(.delete, "maintenance/types/\(type.id)")
        }
        if runner.errorMessage == nil {
            dismiss()
            await reload()
        }
    }
}

// MARK: - Type editor

struct MaintenanceTypeEditor: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let existing: MaintenanceTypeInfo?
    let printers: [MaintenancePrinterOverview]
    var onSaved: () -> Void

    @State private var name = ""
    @State private var description = ""
    @State private var kind = "hours"
    @State private var interval = "100"
    @State private var icon = "Wrench"
    @State private var wikiURL = ""
    @State private var selectedPrinters: Set<Int> = []
    @State private var runner = ActionRunner()
    @State private var didLoad = false

    private var intervalValue: Double? { Double(interval.replacingOccurrences(of: ",", with: ".")) }
    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && (intervalValue ?? 0) >= 1
            && (existing != nil || !selectedPrinters.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (e.g. Replace carbon filter)", text: $name)
                    TextField("Description", text: $description, axis: .vertical).lineLimit(1...4)
                }
                Section {
                    Picker("Measured in", selection: $kind) {
                        Text("Print Hours").tag("hours")
                        Text("Calendar Days").tag("days")
                    }
                    .onChange(of: kind) { _, new in
                        // Swap in a sensible default unless the user typed their own value.
                        if interval == (new == "days" ? "100" : "30") { interval = new == "days" ? "30" : "100" }
                    }
                    LabeledContent(kind == "days" ? "Every (days)" : "Every (hours)") {
                        TextField("Interval", text: $interval).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("Interval")
                } footer: {
                    Text(kind == "days" ? "Due after this many days, whether or not the printer was used." : "Due after this many hours of printing.")
                }
                Section("Icon") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 8)], spacing: 8) {
                        ForEach(MaintenanceIcons.all, id: \.name) { entry in
                            Button { icon = entry.name } label: {
                                Image(systemName: entry.symbol)
                                    .frame(width: 40, height: 40)
                                    .foregroundStyle(icon == entry.name ? Color.white : Color.primary)
                                    .background(icon == entry.name ? Color.accentColor : Color.secondary.opacity(0.12), in: .rect(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(entry.name)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section("Guide Link") {
                    TextField("https://wiki.bambulab.com/…", text: $wikiURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                if existing == nil {
                    Section {
                        ForEach(printers) { p in
                            Button {
                                if selectedPrinters.contains(p.printerId) { selectedPrinters.remove(p.printerId) } else { selectedPrinters.insert(p.printerId) }
                            } label: {
                                HStack {
                                    Text(p.printerName).foregroundStyle(.primary)
                                    Spacer()
                                    if selectedPrinters.contains(p.printerId) { Image(systemName: "checkmark").foregroundStyle(.tint) }
                                }
                            }
                        }
                    } header: {
                        Text("Printers")
                    } footer: {
                        if selectedPrinters.isEmpty { Text("Select at least one printer.") }
                    }
                }
            }
            .navigationTitle(existing == nil ? "New Maintenance Type" : "Edit Type")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existing == nil ? "Add" : "Save") { Task { await save() } }.disabled(!isValid || runner.isRunning)
                }
            }
            .onAppear {
                guard !didLoad else { return }
                if let t = existing {
                    name = t.name
                    description = t.description ?? ""
                    kind = t.kind
                    interval = t.interval.rounded() == t.interval ? String(Int(t.interval)) : String(t.interval)
                    icon = t.icon ?? "Wrench"
                    wikiURL = t.wikiUrl ?? ""
                } else if printers.count == 1 {
                    selectedPrinters = [printers[0].printerId]
                }
                didLoad = true
            }
            .actionAlerts(runner)
        }
    }

    private func save() async {
        guard let value = intervalValue else { return }
        let wiki = wikiURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let desc = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: [String: JSONValue] = [
            "name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines)),
            "description": desc.isEmpty ? .null : .string(desc),
            "default_interval_hours": .number(value),
            "interval_type": .string(kind),
            "icon": .string(icon),
            "wiki_url": wiki.isEmpty ? .null : .string(wiki),
        ]
        let printerIds = Array(selectedPrinters)
        await runner.run(nil) {
            if let existing {
                let _: MaintenanceTypeInfo = try await session.client.send(.patch, "maintenance/types/\(existing.id)", body: body)
            } else {
                let created: MaintenanceTypeInfo = try await session.client.send(.post, "maintenance/types", body: body)
                for id in printerIds {
                    let _: MaintenanceItemRecord = try await session.client.send(.post, "maintenance/printers/\(id)/assign/\(created.id)")
                }
            }
        }
        if runner.errorMessage == nil { onSaved(); dismiss() }
    }
}
