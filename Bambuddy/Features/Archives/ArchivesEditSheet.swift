import SwiftUI

/// Edit an archive's name, printer, project, quantity, filament, notes, link,
/// tags, status and failure reason.
struct ArchivesEditSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var printers
    @Environment(ArchivesLookups.self) private var lookups
    @Environment(\.dismiss) private var dismiss

    let archive: ArchivesRecord
    var onSaved: (ArchivesRecord) -> Void

    @State private var name: String
    @State private var printerId: Int?
    @State private var projectId: Int?
    @State private var quantity: Int
    @State private var filamentText: String
    @State private var notes: String
    @State private var externalUrl: String
    @State private var tags: [String]
    @State private var newTag = ""
    @State private var status: String
    @State private var failureReason: String
    @State private var runner = ActionRunner()

    init(archive: ArchivesRecord, onSaved: @escaping (ArchivesRecord) -> Void) {
        self.archive = archive
        self.onSaved = onSaved
        _name = State(initialValue: archive.printName ?? "")
        _printerId = State(initialValue: archive.printerId)
        _projectId = State(initialValue: archive.projectId)
        _quantity = State(initialValue: max(1, archive.quantity ?? 1))
        _filamentText = State(initialValue: archive.filamentUsedGrams.map { Self.gramsString($0) } ?? "")
        _notes = State(initialValue: archive.notes ?? "")
        _externalUrl = State(initialValue: archive.externalUrl ?? "")
        _tags = State(initialValue: archive.tagList)
        _status = State(initialValue: archive.status ?? "completed")
        _failureReason = State(initialValue: archive.failureReason ?? "")
    }

    private static let maxGrams = 100_000.0

    private static func gramsString(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
    }

    private var parsedGrams: Double?? {
        let t = filamentText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if t.isEmpty { return .some(nil) }
        guard let v = Double(t), v.isFinite else { return nil } // unparseable → leave untouched
        return .some(min(max(v, 0), Self.maxGrams))
    }

    private var statusOptions: [String] {
        var list = ArchivesVocabulary.editableStatuses
        if let s = archive.status, !list.contains(s) { list.insert(s, at: 0) }
        return list
    }

    private var tagSuggestions: [String] {
        let q = newTag.trimmingCharacters(in: .whitespaces).lowercased()
        return lookups.tags.map(\.name)
            .filter { !tags.contains($0) && (q.isEmpty || $0.lowercased().contains(q)) }
            .prefix(12).map { $0 }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField(archive.filename ?? "Print name", text: $name)
                }
                Section {
                    Picker("Printer", selection: $printerId) {
                        Text("No Printer").tag(Int?.none)
                        ForEach(printers.printers) { p in Text(p.name).tag(Int?.some(p.id)) }
                        if let id = archive.printerId, printers.printer(id) == nil {
                            Text("Printer #\(id)").tag(Int?.some(id))
                        }
                    }
                    Picker("Project", selection: $projectId) {
                        Text("No Project").tag(Int?.none)
                        ForEach(lookups.assignableProjects(keeping: archive.projectId)) { p in Text(p.name).tag(Int?.some(p.id)) }
                        if let id = archive.projectId, lookups.project(id) == nil {
                            Text(archive.projectName ?? "Project #\(id)").tag(Int?.some(id))
                        }
                    }
                    Stepper(value: $quantity, in: 1...10_000) {
                        LabeledContent("Items Printed", value: "\(quantity)")
                    }
                } footer: {
                    Text("Items printed counts parts for project progress (e.g. 4 copies on one plate).")
                }
                Section {
                    HStack {
                        TextField("Not recorded", text: $filamentText)
                            .keyboardType(.decimalPad)
                        Text("g").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Filament Used")
                } footer: {
                    Text("Only needed when the print was archived without its 3MF. Leave empty for no figure.")
                }
                Section("Status") {
                    Picker("Status", selection: $status) {
                        ForEach(statusOptions, id: \.self) { s in Text(ArchivesVocabulary.statusLabel(s)).tag(s) }
                    }
                    if status == "failed" || status == "aborted" {
                        Picker("Failure Reason", selection: $failureReason) {
                            Text("Not specified").tag("")
                            ForEach(ArchivesVocabulary.failureReasons, id: \.key) { r in Text(r.label).tag(r.key) }
                            if !failureReason.isEmpty, !ArchivesVocabulary.failureReasons.contains(where: { $0.key == failureReason }) {
                                Text(failureReason).tag(failureReason)
                            }
                        }
                    }
                }
                Section("Notes") {
                    TextField("Notes about this print", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                }
                Section {
                    TextField("https://printables.com/model/…", text: $externalUrl)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("External Link")
                } footer: {
                    Text("Link to the model page (Printables, Thingiverse, …).")
                }
                tagsSection
            }
            .navigationTitle("Edit Archive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if runner.isRunning { ProgressView() } else { Button("Save") { Task { await save() } } }
                }
            }
            .actionAlerts(runner)
        }
    }

    private var tagsSection: some View {
        Section("Tags") {
            if !tags.isEmpty {
                ArchivesFlowLayout(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        Button { tags.removeAll { $0 == tag } } label: {
                            HStack(spacing: 4) {
                                Text(tag)
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .font(.subheadline)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.accentColor.opacity(0.15), in: .capsule)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove tag \(tag)")
                    }
                }
                .padding(.vertical, 2)
            }
            HStack {
                TextField("Add tag", text: $newTag)
                    .textInputAutocapitalization(.never)
                    .onSubmit(addTypedTag)
                Button("Add", action: addTypedTag)
                    .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !tagSuggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(tagSuggestions, id: \.self) { tag in
                            Button { tags.append(tag); newTag = "" } label: {
                                Label(tag, systemImage: "plus")
                                    .font(.caption)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(.quaternary, in: .capsule)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func addTypedTag() {
        for part in newTag.split(separator: ",") {
            let t = part.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, !tags.contains(t) { tags.append(t) }
        }
        newTag = ""
    }

    private func save() async {
        addTypedTag()
        var body = ArchivesUpdate()
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        if !trimmedName.isEmpty, trimmedName != archive.printName { body.set("print_name", trimmedName) }
        if printerId != archive.printerId { body.set("printer_id", printerId) }
        if projectId != archive.projectId { body.set("project_id", projectId) }
        if quantity != (archive.quantity ?? 1) { body.set("quantity", quantity) }
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedNotes != (archive.notes ?? "") { body.set("notes", trimmedNotes) }
        let url = externalUrl.trimmingCharacters(in: .whitespaces)
        if url != (archive.externalUrl ?? "") { body.set("external_url", url.isEmpty ? nil : url) }
        let joinedTags = tags.joined(separator: ", ")
        if tags != archive.tagList { body.set("tags", joinedTags) }
        if let grams = parsedGrams, grams != archive.filamentUsedGrams { body.set("filament_used_grams", grams) }
        if status != archive.status { body.set("status", status) }
        if status == "failed" || status == "aborted" {
            if failureReason != (archive.failureReason ?? "") { body.set("failure_reason", failureReason.isEmpty ? nil : failureReason) }
        } else if archive.isFailed, archive.failureReason != nil {
            body.set("failure_reason", nil as String?)
        }
        if body.isEmpty { dismiss(); return }
        await runner.run {
            let updated: ArchivesRecord = try await session.client.send(.patch, "archives/\(archive.id)", body: body)
            onSaved(updated)
            dismiss()
        }
    }
}
