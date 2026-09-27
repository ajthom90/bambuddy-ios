import SwiftUI
import UniformTypeIdentifiers

// MARK: - Imported (local) presets tab

struct ProfilesLocalTab: View {
    @Environment(AppSession.self) private var session
    @State private var loader = Loader<ProfilesLocalPresetsResponse>()
    @State private var runner = ActionRunner()
    @State private var search = ""
    @State private var showImporter = false
    @State private var deleteTarget: ProfilesLocalPreset?
    @State private var importSummary: String?

    private var canUpdate: Bool { session.can("settings:update") }

    private static let importTypes: [UTType] = {
        var types: [UTType] = [.json, .zip]
        for ext in ["orca_filament", "bbscfg", "bbsflmt"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        types.append(.data)
        return types
    }()

    var body: some View {
        LoadingContent(loader: loader, retry: load) { response in
            List {
                if canUpdate {
                    Section {
                        Button {
                            showImporter = true
                        } label: {
                            HStack {
                                Label("Import Presets", systemImage: "square.and.arrow.down")
                                if runner.isRunning { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(runner.isRunning)
                    } footer: {
                        Text("Import OrcaSlicer or Bambu Studio exports: .json, .zip, .orca_filament, .bbscfg or .bbsflmt files.")
                    }
                }
                if response.totalCount == 0 {
                    ContentUnavailableView {
                        Label("No Imported Presets", systemImage: "externaldrive")
                    } description: {
                        Text("Presets you import from a slicer are stored on the server and can be used for slicing.")
                    }
                } else {
                    let shown = ProfilesPresetKind.allCases.map { ($0, filtered(response.presets($0))) }
                    if shown.allSatisfy({ $0.1.isEmpty }) {
                        ContentUnavailableView.search(text: search)
                    }
                    ForEach([ProfilesPresetKind.filament, .process, .printer]) { kind in
                        let rows = filtered(response.presets(kind))
                        if !rows.isEmpty {
                            Section {
                                ForEach(rows) { preset in
                                    NavigationLink(value: preset) { ProfilesLocalRow(preset: preset) }
                                        .swipeActions {
                                            if canUpdate {
                                                Button("Delete", systemImage: "trash", role: .destructive) { deleteTarget = preset }
                                            }
                                        }
                                        .contextMenu {
                                            if canUpdate {
                                                Button("Delete", systemImage: "trash", role: .destructive) { deleteTarget = preset }
                                            }
                                        }
                                }
                            } header: {
                                Label("\(kind.title) (\(rows.count))", systemImage: kind.systemImage)
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Search imported presets")
        }
        .refreshable { await load() }
        .task { await load() }
        .navigationDestination(for: ProfilesLocalPreset.self) { preset in
            ProfilesLocalDetail(preset: preset, canDelete: canUpdate) { await load() }
        }
        .toolbar {
            if canUpdate {
                ToolbarItem(placement: .primaryAction) {
                    Button { showImporter = true } label: { Label("Import", systemImage: "square.and.arrow.down") }
                        .disabled(runner.isRunning)
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.importTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await importFiles(urls) } }
        }
        .confirm("Delete \(deleteTarget?.name ?? "preset")?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                 message: "The imported preset is removed from the server.") {
            if let target = deleteTarget { Task { await delete(target) } }
        }
        .alert("Import Finished", isPresented: Binding(get: { importSummary != nil }, set: { if !$0 { importSummary = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(importSummary ?? "") }
        .actionAlerts(runner)
    }

    private func filtered(_ list: [ProfilesLocalPreset]) -> [ProfilesLocalPreset] {
        guard !search.isEmpty else { return list }
        return list.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || ($0.filamentType?.localizedCaseInsensitiveContains(search) ?? false)
                || ($0.filamentVendor?.localizedCaseInsensitiveContains(search) ?? false)
        }
    }

    private func load() async {
        await loader.load { try await session.client.get("local-presets/") }
    }

    private func importFiles(_ urls: [URL]) async {
        var imported = 0, skipped = 0
        var errors: [String] = []
        await runner.run {
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                let result: ProfilesImportResult = try await session.client.upload(
                    "local-presets/import",
                    files: [UploadFile(fieldName: "file", fileName: url.lastPathComponent, mimeType: Self.mimeType(for: url), data: data)])
                imported += result.imported
                skipped += result.skipped
                errors += result.errors ?? []
            }
        }
        await load()
        guard runner.errorMessage == nil else { return }
        var parts = ["Imported \(imported) preset\(imported == 1 ? "" : "s")."]
        if skipped > 0 { parts.append("Skipped \(skipped) already present or unsupported.") }
        if !errors.isEmpty { parts.append("\(errors.count) error\(errors.count == 1 ? "" : "s"):\n" + errors.prefix(5).joined(separator: "\n")) }
        importSummary = parts.joined(separator: "\n")
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "json": return "application/json"
        case "zip", "bbscfg", "bbsflmt", "orca_filament": return "application/zip"
        default: return "application/octet-stream"
        }
    }

    private func delete(_ preset: ProfilesLocalPreset) async {
        await runner.run("Preset deleted") {
            try await session.client.call(.delete, "local-presets/\(preset.id)")
            await load()
        }
    }
}

private struct ProfilesLocalRow: View {
    let preset: ProfilesLocalPreset

    var body: some View {
        HStack(spacing: 10) {
            if preset.kind == .filament {
                let explicit = preset.explicitColorHex
                ColorSwatch(hex: explicit ?? ProfilesPresetMeta.materialColorHex(preset.resolvedMaterial), size: 18)
                    .opacity(explicit == nil ? 0.5 : 1)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(preset.name).lineLimit(2)
                HStack(spacing: 4) {
                    if let m = preset.resolvedMaterial { StatusBadge(text: m, color: .accentColor) }
                    if let v = preset.resolvedVendor { Text(v).font(.caption).foregroundStyle(.secondary) }
                    if let min = preset.nozzleTempMin, let max = preset.nozzleTempMax {
                        Text("\(min)–\(max)°C").font(.caption).foregroundStyle(.secondary)
                    }
                    StatusBadge(text: preset.source?.capitalized ?? "Imported")
                }
            }
        }
    }
}

private struct ProfilesLocalDetail: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let preset: ProfilesLocalPreset
    let canDelete: Bool
    let onChanged: () async -> Void
    @State private var detail = Loader<ProfilesLocalPresetDetail>()
    @State private var runner = ActionRunner()
    @State private var confirmDelete = false

    var body: some View {
        LoadingContent(loader: detail, retry: load) { d in
            ProfilesSettingsBrowser(title: preset.name, settings: d.setting?.objectValue ?? [:], header: AnyView(summary))
        }
        .navigationTitle(preset.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .toolbar {
            if canDelete {
                ToolbarItem(placement: .primaryAction) {
                    Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .confirm("Delete \(preset.name)?", isPresented: $confirmDelete, message: "The imported preset is removed from the server.") {
            Task {
                await runner.run {
                    try await session.client.call(.delete, "local-presets/\(preset.id)")
                    await onChanged()
                    dismiss()
                }
            }
        }
        .actionAlerts(runner)
    }

    private var summary: some View {
        Section {
            InfoRow("Type", preset.kind.title)
            InfoRow("Source", preset.source?.capitalized)
            if let m = preset.resolvedMaterial { InfoRow("Material", m) }
            if let v = preset.resolvedVendor { InfoRow("Vendor", v) }
            if let min = preset.nozzleTempMin, let max = preset.nozzleTempMax { InfoRow("Nozzle Temperature", "\(min)–\(max) °C") }
            if let c = preset.filamentCost, !c.isEmpty { InfoRow("Cost", c) }
            if let d = preset.filamentDensity, !d.isEmpty { InfoRow("Density", "\(d) g/cm³") }
            if let pa = preset.pressureAdvance, !pa.isEmpty { InfoRow("Pressure Advance", pa) }
            if let hex = preset.explicitColorHex {
                LabeledContent("Colour") { HStack { Text("#\(hex)"); ColorSwatch(hex: hex, size: 18) } }
            }
            if let printers = preset.compatiblePrinterList { InfoRow("Compatible Printers", printers) }
            if let inherits = preset.inherits, !inherits.isEmpty, inherits != preset.name { InfoRow("Inherits", inherits) }
            if let v = preset.version { InfoRow("Version", v) }
            InfoRow("Imported", Fmt.date(preset.createdAt))
        }
    }

    private func load() async {
        await detail.load { try await session.client.get("local-presets/\(preset.id)") }
    }
}
