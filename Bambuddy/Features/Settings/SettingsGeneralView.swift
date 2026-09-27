import SwiftUI
import Charts

/// General server settings: language and formats, default printer, archiving, the file
/// manager, auto-purge schedules and data management.
struct SettingsGeneralView: View {
    @Environment(ServerSettingsStore.self) private var store
    @Environment(PrinterStore.self) private var printers
    @Environment(AppSession.self) private var session
    @State private var model = GeneralPageModel()
    @State private var confirmClearLogs = false

    var body: some View {
        SettingsForm("General") {
            Section {
                SettingsPicker("Language", key: "language", choices: SettingsGeneralChoices.languageCodes.map {
                    ($0, SettingsGeneralChoices.languageLabel($0))
                })
                SettingsPicker("Date Format", key: "date_format", choices: [
                    ("system", "System Default"),
                    ("us", "MM/DD/YYYY"),
                    ("eu", "DD/MM/YYYY"),
                    ("iso", "YYYY-MM-DD"),
                ])
                SettingsPicker("Time Format", key: "time_format", choices: [
                    ("system", "System Default"),
                    ("12h", "12-hour"),
                    ("24h", "24-hour"),
                ])
            } header: {
                Text("Language & Formats")
            } footer: {
                Text("Used by the web interface and for text the server generates, such as notifications. This app follows your device's language and region settings.")
            }

            Section {
                SettingsPicker("Default Printer", key: "default_printer_id", options: defaultPrinterOptions)
            } footer: {
                Text("Preselected when uploading, reprinting or scheduling a print.")
            }

            archiveSection
            if session.can("archives:purge") { archivePurgeSection }
            fileManagerSection
            if session.can("library:purge") { trashPurgeSection }
            dataSection
            if session.can("system:read") { storageSection }
        }
        .actionAlerts(model.runner)
        .confirm("Clear Notification Log?", isPresented: $confirmClearLogs,
                 message: "Log entries older than 30 days will be permanently deleted.", action: "Clear") {
            Task { await model.clearNotificationLogs(session.client) }
        }
        .task { await loadExtras() }
    }

    private func loadExtras() async {
        let client = session.client
        let printerStore = printers, model = model
        let needPrinters = printerStore.printers.isEmpty
        let canPurge = session.can("archives:purge"), canTrash = session.can("library:purge"), canUsage = session.can("system:read")
        await withDiscardingTaskGroup { group in
            if needPrinters { group.addTask { await printerStore.refresh() } }
            group.addTask { await model.loadFfmpeg(client) }
            if canPurge { group.addTask { await model.loadArchivePurge(client) } }
            if canTrash { group.addTask { await model.loadTrash(client) } }
            if canUsage { group.addTask { await model.loadUsage(client, refresh: false) } }
        }
    }

    private var defaultPrinterOptions: [(value: JSONValue, label: String)] {
        [(JSONValue.null, "None")] + printers.printers.map { (JSONValue.number(Double($0.id)), $0.name) }
    }

    // MARK: Archiving

    @ViewBuilder private var archiveSection: some View {
        Section {
            SettingsToggle("Archive Prints Automatically", key: "auto_archive", help: "Keep a record of every finished print.", default: true)
            SettingsToggle("Save Thumbnails", key: "save_thumbnails", help: "Extract preview images from 3MF files.", default: true)
            SettingsToggle("Capture Finish Photo", key: "capture_finish_photo", help: "Take a camera snapshot when a print completes.", default: true)
            if store.bool("capture_finish_photo", default: true) {
                SettingsToggle("Raise Plate for Photo", key: "finish_photo_restore_plate",
                               help: "Lift the finished print back into the camera's view for the photo, then lower it again.", default: true)
                if model.ffmpeg?.installed == false {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("ffmpeg Not Installed").font(.subheadline.weight(.semibold))
                            Text("The server needs ffmpeg to capture camera frames. Install it on the Bambuddy host (for example with your package manager) to get finish photos.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
            }
        } header: {
            Text("Archiving")
        }
    }

    @ViewBuilder private var archivePurgeSection: some View {
        Section {
            if let settings = model.archivePurge {
                let enabled = settings.enabled ?? false
                Toggle(isOn: Binding(get: { enabled }, set: { v in model.saveArchivePurge(session.client) { $0.enabled = v } })) {
                    SettingsLabel("Delete Old Archives", help: "Once a day, permanently remove archives older than the age below.")
                }
                GeneralDaysField(title: "Older Than", value: settings.days ?? 365) { days in
                    model.saveArchivePurge(session.client) { $0.days = days }
                }
                .disabled(!enabled)
                Toggle(isOn: Binding(get: { settings.purgeStats ?? false }, set: { v in model.saveArchivePurge(session.client) { $0.purgeStats = v } })) {
                    SettingsLabel("Remove from Statistics", help: "Also delete the print history behind statistics. When off, purged prints still count.")
                }
                .disabled(!enabled)
            } else if let error = model.archivePurgeError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        } header: {
            Text("Archive Auto-Purge")
        } footer: {
            Text("Ages from 7 to 3650 days are allowed.")
        }
    }

    // MARK: File manager

    @ViewBuilder private var fileManagerSection: some View {
        Section {
            SettingsPicker("Archive Prints from Files", key: "library_archive_mode", choices: [
                ("always", "Always"),
                ("never", "Never"),
                ("ask", "Ask Each Time"),
            ])
            SettingsNumberField("Low Disk Space Warning", key: "library_disk_warning_gb", unit: "GB",
                                help: "Warn when free space drops below this amount.",
                                integer: false, range: 0.5...100)
        } header: {
            Text("File Manager")
        } footer: {
            Text("Choose whether printing a file from the file manager also creates an archive entry.")
        }
    }

    @ViewBuilder private var trashPurgeSection: some View {
        Section {
            if let settings = model.trash {
                let enabled = settings.autoPurgeEnabled ?? false
                Toggle(isOn: Binding(get: { enabled }, set: { v in model.saveTrash(session.client) { $0.autoPurgeEnabled = v } })) {
                    SettingsLabel("Clean Up Unused Files", help: "Once a day, move files that haven't been printed recently to the trash.")
                }
                GeneralDaysField(title: "Unused For", value: settings.autoPurgeDays ?? 90) { days in
                    model.saveTrash(session.client) { $0.autoPurgeDays = days }
                }
                .disabled(!enabled)
                Toggle("Include Never-Printed Files", isOn: Binding(
                    get: { settings.autoPurgeIncludeNeverPrinted ?? true },
                    set: { v in model.saveTrash(session.client) { $0.autoPurgeIncludeNeverPrinted = v } }))
                    .disabled(!enabled)
            } else if let error = model.trashError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        } header: {
            Text("File Manager Auto-Purge")
        } footer: {
            Text("Files moved to the trash can be restored until the trash retention period ends.")
        }
    }

    // MARK: Data

    @ViewBuilder private var dataSection: some View {
        let canClear = session.can("notifications:delete")
        let canBackup = session.can("settings:backup")
        if canClear || canBackup {
            Section {
                if canClear {
                    Button(role: .destructive) { confirmClearLogs = true } label: {
                        Label("Clear Notification Log", systemImage: "trash")
                    }
                }
                if canBackup {
                    NavigationLink {
                        SettingsBackupView()
                    } label: {
                        Label("Backup & Restore", systemImage: "externaldrive.badge.timemachine")
                    }
                }
            } header: {
                Text("Data")
            } footer: {
                if canClear { Text("Clearing removes notification log entries older than 30 days.") }
            }
        }
    }

    @ViewBuilder private var storageSection: some View {
        Section {
            if let value = model.usage {
                GeneralStorageContent(usage: value)
            } else if let error = model.usageError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            } else {
                HStack { Text("Measuring…").foregroundStyle(.secondary); Spacer(); ProgressView() }
            }
            Button {
                Task { await model.loadUsage(session.client, refresh: true) }
            } label: {
                HStack {
                    Label("Rescan Storage", systemImage: "arrow.clockwise")
                    if model.isLoadingUsage { Spacer(); ProgressView() }
                }
            }
            .disabled(model.isLoadingUsage)
        } header: {
            Text("Storage Usage")
        } footer: {
            if let generated = model.usage?.generatedAt {
                Text("Measured \(Fmt.relative(generated)). Results are cached for a few minutes; rescan for fresh numbers.")
            }
        }
    }
}

// MARK: - Page model

@MainActor
@Observable
private final class GeneralPageModel {
    var runner = ActionRunner()
    var ffmpeg: SettingsGeneralFfmpegStatus?
    var archivePurge: SettingsGeneralArchivePurge?
    var archivePurgeError: String?
    var trash: SettingsGeneralTrashSettings?
    var trashError: String?
    var usage: SettingsGeneralStorageUsage?
    var usageError: String?
    var isLoadingUsage = false

    func loadFfmpeg(_ client: APIClient) async {
        ffmpeg = try? await client.get("settings/check-ffmpeg")
    }

    func loadArchivePurge(_ client: APIClient) async {
        do {
            archivePurge = try await client.get("archives/purge/settings")
            archivePurgeError = nil
        } catch {
            if archivePurge == nil { archivePurgeError = error.localizedDescription }
        }
    }

    func loadTrash(_ client: APIClient) async {
        do {
            trash = try await client.get("library/trash/settings")
            trashError = nil
        } catch {
            if trash == nil { trashError = error.localizedDescription }
        }
    }

    func loadUsage(_ client: APIClient, refresh: Bool) async {
        isLoadingUsage = true
        defer { isLoadingUsage = false }
        do {
            usage = try await client.get("system/storage-usage", query: ["refresh": refresh ? QueryValue.bool(true) : nil])
            usageError = nil
        } catch {
            if usage == nil { usageError = error.localizedDescription } else { runner.errorMessage = error.localizedDescription }
        }
    }

    /// Optimistically applies `change` and PUTs the full record (the endpoint replaces it).
    func saveArchivePurge(_ client: APIClient, _ change: (inout SettingsGeneralArchivePurge) -> Void) {
        guard let previous = archivePurge else { return }
        var next = previous
        change(&next)
        let body = SettingsGeneralArchivePurge(enabled: next.enabled ?? false, days: next.days ?? 365, purgeStats: next.purgeStats ?? false)
        archivePurge = body
        Task {
            await runner.run {
                do {
                    archivePurge = try await client.send(.put, "archives/purge/settings", body: body)
                } catch {
                    archivePurge = previous
                    throw error
                }
            }
        }
    }

    func saveTrash(_ client: APIClient, _ change: (inout SettingsGeneralTrashSettings) -> Void) {
        guard let previous = trash else { return }
        var next = previous
        change(&next)
        // `retention_days` is required by the endpoint; it's managed from the trash itself, so echo it back.
        let body = SettingsGeneralTrashSettings(retentionDays: next.retentionDays ?? 30,
                                                autoPurgeEnabled: next.autoPurgeEnabled ?? false,
                                                autoPurgeDays: next.autoPurgeDays ?? 90,
                                                autoPurgeIncludeNeverPrinted: next.autoPurgeIncludeNeverPrinted ?? true)
        trash = body
        Task {
            await runner.run {
                do {
                    trash = try await client.send(.put, "library/trash/settings", body: body)
                } catch {
                    trash = previous
                    throw error
                }
            }
        }
    }

    func clearNotificationLogs(_ client: APIClient) async {
        await runner.run {
            let result: SettingsGeneralClearLogsResult = try await client.send(.delete, "notifications/logs", query: ["older_than_days": 30])
            let count = result.deleted ?? 0
            runner.successMessage = "Deleted \(count) log entr\(count == 1 ? "y" : "ies")"
        }
    }
}

// MARK: - Helpers

/// Day count edited in place, clamped to 7…3650 and committed on return or focus loss.
private struct GeneralDaysField: View {
    let title: String
    let value: Int
    let commit: (Int) -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField("Days", text: $draft)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 80)
                    .focused($focused)
                    .onSubmit(apply)
                Text("days").foregroundStyle(.secondary)
            }
        }
        .onAppear { draft = String(value) }
        .onChange(of: value) { _, v in if !focused { draft = String(v) } }
        .onChange(of: focused) { _, isFocused in if !isFocused { apply() } }
    }

    private func apply() {
        guard let parsed = Int(draft.trimmingCharacters(in: .whitespaces)) else { draft = String(value); return }
        let clamped = SettingsGeneralChoices.clampPurgeDays(parsed)
        draft = String(clamped)
        if clamped != value { commit(clamped) }
    }
}

/// Storage breakdown rows: a stacked bar, one row per category, the total and "other" details.
private struct GeneralStorageContent: View {
    let usage: SettingsGeneralStorageUsage

    var body: some View {
        let categories = usage.visibleCategories
        if categories.isEmpty {
            Text("No data stored yet.").foregroundStyle(.secondary)
        } else {
            Chart(categories) { category in
                BarMark(x: .value("Size", category.bytes ?? 0), y: .value("Storage", "Total"))
                    .foregroundStyle(by: .value("Category", category.displayName))
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(position: .bottom, alignment: .leading)
            .frame(height: 64)
            .accessibilityHidden(true)

            ForEach(categories) { category in
                LabeledContent(category.displayName) {
                    HStack(spacing: 6) {
                        Text(category.formatted ?? Fmt.bytes(category.bytes))
                        Text(Self.percent(category.percentOfTotal)).foregroundStyle(.tertiary)
                    }
                    .monospacedDigit()
                }
            }
        }
        LabeledContent("Total") {
            Text(usage.totalFormatted ?? Fmt.bytes(usage.totalBytes)).fontWeight(.semibold).monospacedDigit()
        }
        if let errors = usage.scanErrors, errors > 0 {
            Label("\(errors) file\(errors == 1 ? "" : "s") couldn't be measured", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .font(.footnote)
        }
        if let other = usage.otherBreakdown, !other.isEmpty {
            DisclosureGroup("Other Files") {
                ForEach(Array(other.enumerated()), id: \.offset) { _, item in
                    LabeledContent {
                        HStack(spacing: 6) {
                            Text(item.formatted ?? Fmt.bytes(item.bytes))
                            Text(Self.percent(item.percentOfTotal)).foregroundStyle(.tertiary)
                        }
                        .monospacedDigit()
                    } label: {
                        HStack(spacing: 6) {
                            Text(item.label ?? item.bucket ?? "Other")
                            StatusBadge(text: item.kind == "system" ? "System" : "Data",
                                        color: item.kind == "system" ? .secondary : .green)
                        }
                    }
                }
            }
        }
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "" }
        return value.formatted(.number.precision(.fractionLength(1))) + "%"
    }
}
