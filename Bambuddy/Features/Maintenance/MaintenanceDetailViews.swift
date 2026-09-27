import SwiftUI

// MARK: - Item detail (status, schedule, history)

struct MaintenanceItemDetailView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let store: MaintenanceStore
    let printerId: Int
    let itemId: Int
    let reload: () async -> Void

    @State private var history = Loader<[MaintenanceHistoryEntry]>()
    @State private var runner = ActionRunner()
    @State private var performing = false
    @State private var editingInterval = false
    @State private var confirmRemove = false

    var body: some View {
        Group {
            if let item = store.item(printerId: printerId, itemId: itemId) {
                content(item)
            } else {
                ContentUnavailableView("Item Not Found", systemImage: "wrench.adjustable",
                                       description: Text("This maintenance item no longer exists."))
            }
        }
        .navigationTitle(store.item(printerId: printerId, itemId: itemId)?.maintenanceTypeName ?? "Maintenance")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadHistory() }
        .actionAlerts(runner)
    }

    private func content(_ item: MaintenanceItemStatus) -> some View {
        let type = store.type(item.maintenanceTypeId)
        let canUpdate = session.can("maintenance:update")
        return List {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: MaintenanceIcons.symbol(for: item.maintenanceTypeIcon))
                        .font(.title2)
                        .foregroundStyle(item.statusColor)
                        .frame(width: 52, height: 52)
                        .background(item.statusColor.opacity(0.14), in: .rect(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.maintenanceTypeName).font(.headline)
                        Text([item.printerName, item.printerModel].compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(.secondary)
                        Label(item.statusText, systemImage: item.statusSymbol).font(.subheadline).foregroundStyle(item.statusColor)
                    }
                }
                ProgressView(value: item.progress).tint(item.statusColor)
                if let d = type?.description, !d.isEmpty {
                    Text(d).font(.subheadline).foregroundStyle(.secondary)
                }
                if let s = item.maintenanceTypeWikiUrl ?? type?.wikiUrl, let url = URL(string: s) {
                    Link(destination: url) { Label("View Guide", systemImage: "book") }
                }
            }

            Section("Schedule") {
                LabeledContent("Interval") {
                    VStack(alignment: .trailing) {
                        Text(MaintenanceFormat.interval(item.intervalHours, type: item.intervalType))
                        if let type, type.interval != item.intervalHours || type.kind != item.intervalType {
                            Text("Default: \(MaintenanceFormat.interval(type.interval, type: type.kind))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if item.isDaysBased {
                    InfoRow("Since last done", item.daysSinceMaintenance.map { MaintenanceFormat.amount($0, daysBased: true) } ?? "—")
                } else {
                    InfoRow("Printer print time", "\(Int(item.currentHours.rounded())) h")
                    InfoRow("Since last done", MaintenanceFormat.amount(max(0, item.hoursSinceMaintenance), daysBased: false))
                }
                InfoRow("Last done", item.lastPerformedAt.map { Fmt.date($0) } ?? "Never")
                if canUpdate {
                    Button { editingInterval = true } label: { Label("Change Interval…", systemImage: "slider.horizontal.3") }
                }
            }

            Section {
                if canUpdate {
                    Button { performing = true } label: { Label("Mark as Done…", systemImage: "checkmark.circle") }
                        .disabled(!item.enabled)
                    Toggle(isOn: Binding(get: { item.enabled }, set: { v in Task { await setEnabled(item, v) } })) {
                        Label("Track on This Printer", systemImage: "bell")
                    }
                }
                if type?.isSystem == false, session.can("maintenance:delete") {
                    Button(role: .destructive) { confirmRemove = true } label: { Label("Remove from Printer", systemImage: "minus.circle") }
                }
            } footer: {
                if !item.enabled { Text("Disabled items are not counted as due and don't send reminders.") }
            }

            Section("History") {
                if let entries = history.value {
                    if entries.isEmpty { Text("Not performed yet.").foregroundStyle(.secondary) }
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(Fmt.date(entry.performedAt)).font(.subheadline)
                                Spacer()
                                Text("at \(Int(entry.hoursAtMaintenance.rounded())) h").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                            if let n = entry.notes, !n.isEmpty {
                                Text(n).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } else if let e = history.error {
                    Text(e).foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
        }
        .sheet(isPresented: $performing) {
            MaintenancePerformSheet(item: item) { Task { await reload(); await loadHistory() } }
        }
        .sheet(isPresented: $editingInterval) {
            MaintenanceIntervalEditor(item: item, type: type) { Task { await reload() } }
        }
        .confirm("Remove from Printer?", isPresented: $confirmRemove,
                 message: "“\(item.maintenanceTypeName)” will no longer be tracked on \(item.printerName). Its history is removed too.", action: "Remove") {
            Task { await remove(item) }
        }
        .refreshable { await reload(); await loadHistory() }
    }

    private func loadHistory() async {
        await history.load { try await session.client.get("maintenance/items/\(itemId)/history") }
    }

    private func setEnabled(_ item: MaintenanceItemStatus, _ enabled: Bool) async {
        await runner.run(nil) {
            try await session.client.call(.patch, "maintenance/items/\(item.id)", body: ["enabled": JSONValue.bool(enabled)])
        }
        await reload()
    }

    private func remove(_ item: MaintenanceItemStatus) async {
        await runner.run(nil) {
            try await session.client.call(.delete, "maintenance/items/\(item.id)")
        }
        if runner.errorMessage == nil {
            await reload()
            dismiss()
        }
    }
}

// MARK: - Interval override

struct MaintenanceIntervalEditor: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let item: MaintenanceItemStatus
    let type: MaintenanceTypeInfo?
    var onSaved: () -> Void

    @State private var kind = "hours"
    @State private var value = ""
    @State private var runner = ActionRunner()

    private var defaultInterval: Double { type?.interval ?? item.intervalHours }
    private var defaultKind: String { type?.kind ?? "hours" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Measured in", selection: $kind) {
                        Text("Print Hours").tag("hours")
                        Text("Calendar Days").tag("days")
                    }
                    LabeledContent(kind == "days" ? "Every (days)" : "Every (hours)") {
                        TextField("Interval", text: $value).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("\(item.maintenanceTypeName) on \(item.printerName)")
                } footer: {
                    Text("Default: \(MaintenanceFormat.interval(defaultInterval, type: defaultKind)).")
                }
                Section {
                    Button("Reset to Default") { Task { await save(reset: true) } }
                }
            }
            .navigationTitle("Interval")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save(reset: false) } }
                        .disabled((Double(value.replacingOccurrences(of: ",", with: ".")) ?? 0) < 1 || runner.isRunning)
                }
            }
            .onAppear {
                kind = item.intervalType
                value = item.intervalHours.rounded() == item.intervalHours ? String(Int(item.intervalHours)) : String(item.intervalHours)
            }
            .actionAlerts(runner)
        }
        .presentationDetents([.medium, .large])
    }

    private func save(reset: Bool) async {
        var body: [String: JSONValue] = ["custom_interval_hours": .null, "custom_interval_type": .null]
        if !reset, let v = Double(value.replacingOccurrences(of: ",", with: ".")), v >= 1 {
            // Matching the type's defaults is stored as "no override".
            if abs(v - defaultInterval) >= 0.01 || kind != defaultKind { body["custom_interval_hours"] = .number(v) }
            if kind != defaultKind { body["custom_interval_type"] = .string(kind) }
        }
        await runner.run(nil) {
            try await session.client.call(.patch, "maintenance/items/\(item.id)", body: body)
        }
        if runner.errorMessage == nil { onSaved(); dismiss() }
    }
}
