import SwiftUI

/// Slicer profile management: Bambu Cloud presets, Orca Cloud presets,
/// imported (local) presets and per-printer pressure-advance (K) profiles.
struct ProfilesRootView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case cloud, orca, local, kprofiles
        var id: String { rawValue }
        var title: String {
            switch self {
            case .cloud: return "Bambu Cloud"
            case .orca: return "Orca Cloud"
            case .local: return "Imported"
            case .kprofiles: return "K-Profiles"
            }
        }
        var shortTitle: String {
            switch self {
            case .cloud: return "Bambu"
            case .orca: return "Orca"
            case .local: return "Imported"
            case .kprofiles: return "K-Profiles"
            }
        }
    }

    @AppStorage("profiles.tab") private var tab: Tab = .cloud
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        NavigationStack {
            Group {
                switch tab {
                case .cloud: ProfilesCloudTab()
                case .orca: ProfilesOrcaTab()
                case .local: ProfilesLocalTab()
                case .kprofiles: ProfilesKProfilesTab()
                }
            }
            .id(tab)
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker("Profile Source", selection: $tab) {
                    ForEach(Tab.allCases) { t in
                        Text(sizeClass == .compact ? t.shortTitle : t.title).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)
                .background(.bar)
            }
            .navigationTitle("Profiles")
            .toolbarTitleDisplayMode(.inline)
            #if DEBUG
            .onAppear {
                // Launch argument `-profilesTab kprofiles` selects a tab (for screenshots).
                if let raw = UserDefaults.standard.string(forKey: "profilesTab"), let t = Tab(rawValue: raw) { tab = t }
            }
            #endif
        }
    }
}

// MARK: - Shared preset list pieces

/// Anything that can be listed/filtered as a slicer preset.
protocol ProfilesPresetListable: Identifiable, Hashable {
    var settingId: String { get }
    var name: String { get }
    var kind: ProfilesPresetKind { get }
    var ownedByUser: Bool { get }
}

extension ProfilesSlicerSetting: ProfilesPresetListable {
    var ownedByUser: Bool { isUserPreset }
}

extension ProfilesOrcaProfileMeta: ProfilesPresetListable {
    var ownedByUser: Bool { true }
}

struct ProfilesPresetFilter: Equatable {
    enum Owner: String, CaseIterable { case all, custom, builtin }
    var kind: ProfilesPresetKind?
    var owner: Owner = .all
    var printerModel: String?
    var printerId: Int?
    var nozzle: String?
    var filament: String?
    var layer: String?

    var isActive: Bool {
        kind != nil || owner != .all || printerId != nil || nozzle != nil || filament != nil || layer != nil
    }

    func matches<P: ProfilesPresetListable>(_ p: P, meta: ProfilesPresetMeta.Info, search: String) -> Bool {
        if let kind, p.kind != kind { return false }
        switch owner {
        case .all: break
        case .custom: if !p.ownedByUser { return false }
        case .builtin: if p.ownedByUser { return false }
        }
        if let model = printerModel?.lowercased(), !model.isEmpty {
            let presetPrinter = meta.printer?.lowercased() ?? ""
            if !(presetPrinter.contains(model) || model.contains(presetPrinter)) { return false }
        }
        if let nozzle, meta.nozzle != nozzle { return false }
        if let filament, meta.filamentType != filament { return false }
        if let layer, meta.layerHeight != layer { return false }
        if !search.isEmpty, !p.name.localizedCaseInsensitiveContains(search) { return false }
        return true
    }
}

/// Precomputed metadata for a preset list so filtering stays fast with thousands of rows.
struct ProfilesIndexedPresets<P: ProfilesPresetListable> {
    var items: [(preset: P, meta: ProfilesPresetMeta.Info)]
    var nozzles: [String]
    var filaments: [String]
    var layers: [String]

    init(_ presets: [P]) {
        items = presets.map { ($0, ProfilesPresetMeta.extract($0.name)) }
        func numericSort(_ a: String, _ b: String) -> Bool { (Double(a.dropLast(2)) ?? 0) < (Double(b.dropLast(2)) ?? 0) }
        nozzles = Set(items.compactMap(\.meta.nozzle)).sorted(by: numericSort)
        filaments = Set(items.compactMap(\.meta.filamentType)).sorted()
        layers = Set(items.compactMap(\.meta.layerHeight)).sorted(by: numericSort)
    }

    func filtered(_ filter: ProfilesPresetFilter, search: String) -> [ProfilesPresetKind: [(preset: P, meta: ProfilesPresetMeta.Info)]] {
        let matching = items.filter { filter.matches($0.preset, meta: $0.meta, search: search) }
            .sorted { $0.preset.name.localizedStandardCompare($1.preset.name) == .orderedAscending }
        return Dictionary(grouping: matching, by: { $0.preset.kind })
    }

    func count(_ kind: ProfilesPresetKind) -> Int { items.lazy.filter { $0.preset.kind == kind }.count }
}

/// Toolbar menu with every preset filter.
struct ProfilesFilterMenu<P: ProfilesPresetListable>: View {
    @Binding var filter: ProfilesPresetFilter
    let index: ProfilesIndexedPresets<P>
    let printers: [Printer]
    var showOwner = true

    var body: some View {
        Menu {
            Picker("Type", selection: $filter.kind) {
                Text("All Types (\(index.items.count))").tag(ProfilesPresetKind?.none)
                ForEach(ProfilesPresetKind.allCases) { k in
                    Label("\(k.title) (\(index.count(k)))", systemImage: k.systemImage).tag(ProfilesPresetKind?.some(k))
                }
            }
            if showOwner {
                Picker("Owner", selection: $filter.owner) {
                    Text("All Owners").tag(ProfilesPresetFilter.Owner.all)
                    Text("My Presets").tag(ProfilesPresetFilter.Owner.custom)
                    Text("Built-in").tag(ProfilesPresetFilter.Owner.builtin)
                }
            }
            if !printers.isEmpty {
                Menu("Printer") {
                    Picker("Printer", selection: Binding(get: { filter.printerId }, set: { id in
                        filter.printerId = id
                        filter.printerModel = printers.first { $0.id == id }?.model
                    })) {
                        Text("All Printers").tag(Int?.none)
                        ForEach(printers) { p in Text(p.name).tag(Int?.some(p.id)) }
                    }
                }
            }
            optionMenu("Nozzle", values: index.nozzles, selection: $filter.nozzle)
            if filter.kind == nil || filter.kind == .filament {
                optionMenu("Filament", values: index.filaments, selection: $filter.filament)
            }
            if filter.kind == nil || filter.kind == .process {
                optionMenu("Layer Height", values: index.layers, selection: $filter.layer)
            }
            if filter.isActive {
                Divider()
                Button("Clear Filters", systemImage: "xmark.circle", role: .destructive) { filter = ProfilesPresetFilter() }
            }
        } label: {
            Label("Filter", systemImage: filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
    }

    @ViewBuilder
    private func optionMenu(_ title: String, values: [String], selection: Binding<String?>) -> some View {
        if !values.isEmpty {
            Menu(title) {
                Picker(title, selection: selection) {
                    Text("All").tag(String?.none)
                    ForEach(values, id: \.self) { Text($0).tag(String?.some($0)) }
                }
            }
        }
    }
}

/// One preset row with metadata tags.
struct ProfilesPresetRow<P: ProfilesPresetListable>: View {
    let preset: P
    let meta: ProfilesPresetMeta.Info
    var showOwnership = true
    var selectionIndex: Int? = nil
    var dimmed = false

    var body: some View {
        HStack(spacing: 10) {
            if let selectionIndex {
                Text("\(selectionIndex + 1)")
                    .font(.caption.bold()).foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Color.blue, in: .circle)
            } else if showOwnership, preset.ownedByUser {
                Image(systemName: "person.crop.circle.fill").foregroundStyle(.tint)
                    .accessibilityLabel("My preset")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(preset.name).lineLimit(2)
                let tags = tagList
                if !tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(tags, id: \.self) { StatusBadge(text: $0, color: .secondary) }
                    }
                }
            }
        }
        .opacity(dimmed ? 0.4 : 1)
    }

    private var tagList: [String] {
        var tags: [String] = []
        if preset.kind == .filament, let f = meta.filamentType { tags.append(f) }
        if preset.kind == .process, let l = meta.layerHeight { tags.append(l) }
        if let p = meta.printer { tags.append(p) }
        return tags
    }
}

/// Searchable key/value view of a preset's settings, with a raw JSON mode.
struct ProfilesSettingsBrowser: View {
    let title: String
    let settings: [String: JSONValue]
    var header: AnyView? = nil
    @State private var search = ""
    @State private var showJSON = false

    var body: some View {
        List {
            if let header { header }
            if showJSON {
                Section {
                    ScrollView(.horizontal) {
                        Text(ProfilesJSON.pretty(.object(settings)))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .padding(.vertical, 4)
                    }
                }
            } else {
                Section("\(filteredKeys.count) Settings") {
                    ForEach(filteredKeys, id: \.self) { key in
                        NavigationLink {
                            ProfilesSettingValueView(key: key, value: settings[key] ?? .null)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(key).font(.subheadline.monospaced())
                                Text(ProfilesJSON.summary(settings[key])).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Search settings")
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Toggle(isOn: $showJSON) { Label("Show JSON", systemImage: "curlybraces") }
            }
        }
    }

    private var filteredKeys: [String] {
        let keys = settings.keys.sorted()
        guard !search.isEmpty else { return keys }
        return keys.filter { $0.localizedCaseInsensitiveContains(search) || ProfilesJSON.summary(settings[$0]).localizedCaseInsensitiveContains(search) }
    }
}

struct ProfilesSettingValueView: View {
    let key: String
    let value: JSONValue
    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(ProfilesJSON.full(value))
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(key)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: ProfilesJSON.full(value)) { Label("Share", systemImage: "square.and.arrow.up") }
            }
        }
    }
}

// MARK: - Diff

struct ProfilesDiffView: View {
    enum Status: Int { case changed, added, removed, same }
    struct Entry: Identifiable {
        var key: String
        var left: JSONValue?
        var right: JSONValue?
        var status: Status
        var id: String { key }
    }

    let left: [String: JSONValue]
    let right: [String: JSONValue]
    let leftLabel: String
    let rightLabel: String
    @Environment(\.dismiss) private var dismiss
    @State private var onlyChanges = true
    @State private var search = ""

    private var entries: [Entry] {
        Set(left.keys).union(right.keys).subtracting(["inherits", "version"]).map { key in
            let l = left[key], r = right[key]
            let status: Status = l == nil ? .added : r == nil ? .removed : (l == r ? .same : .changed)
            return Entry(key: key, left: l, right: r, status: status)
        }
        .sorted { $0.status.rawValue != $1.status.rawValue ? $0.status.rawValue < $1.status.rawValue : $0.key < $1.key }
    }

    var body: some View {
        let all = entries
        let shown = all.filter { e in
            (!onlyChanges || e.status != .same) &&
            (search.isEmpty || e.key.localizedCaseInsensitiveContains(search)
                || ProfilesJSON.summary(e.left).localizedCaseInsensitiveContains(search)
                || ProfilesJSON.summary(e.right).localizedCaseInsensitiveContains(search))
        }
        NavigationStack {
            List {
                Section {
                    LabeledContent("A", value: leftLabel)
                    LabeledContent("B", value: rightLabel)
                    HStack(spacing: 12) {
                        stat(all.filter { $0.status == .changed }.count, "changed", .orange, "arrow.left.arrow.right")
                        stat(all.filter { $0.status == .added }.count, "added", .green, "plus")
                        stat(all.filter { $0.status == .removed }.count, "removed", .red, "minus")
                        stat(all.filter { $0.status == .same }.count, "same", .secondary, "equal")
                    }
                    .font(.caption)
                    Picker("Show", selection: $onlyChanges) {
                        Text("Differences").tag(true)
                        Text("All Fields").tag(false)
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    if shown.isEmpty {
                        Text(onlyChanges ? "No differences" : "No fields").foregroundStyle(.secondary)
                    }
                    ForEach(shown) { e in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(e.key).font(.subheadline.monospaced())
                                Spacer()
                                StatusBadge(text: label(e.status), color: color(e.status))
                            }
                            HStack(alignment: .top, spacing: 6) {
                                Text(e.left.map { ProfilesJSON.summary($0) } ?? "—")
                                    .foregroundStyle(e.status == .removed || e.status == .changed ? .red : .secondary)
                                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                                Text(e.right.map { ProfilesJSON.summary($0) } ?? "—")
                                    .foregroundStyle(e.status == .added || e.status == .changed ? .green : .secondary)
                            }
                            .font(.caption.monospaced())
                            .lineLimit(3)
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Search fields")
            .navigationTitle("Compare")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func stat(_ n: Int, _ text: String, _ color: Color, _ icon: String) -> some View {
        Label("\(n) \(text)", systemImage: icon).foregroundStyle(color)
    }
    private func label(_ s: Status) -> String {
        switch s { case .changed: return "Changed"; case .added: return "Added"; case .removed: return "Removed"; case .same: return "Same" }
    }
    private func color(_ s: Status) -> Color {
        switch s { case .changed: return .orange; case .added: return .green; case .removed: return .red; case .same: return .secondary }
    }
}

/// A JSON file that can be shared/exported.
struct ProfilesJSONFile: Transferable {
    var fileName: String
    var value: JSONValue

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { file in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let safe = file.fileName.replacingOccurrences(of: "/", with: "-")
            let url = dir.appendingPathComponent(safe.hasSuffix(".json") ? safe : safe + ".json")
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try enc.encode(file.value).write(to: url)
            return SentTransferredFile(url)
        }
    }
}
