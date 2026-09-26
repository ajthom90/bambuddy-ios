import SwiftUI
import PhotosUI

enum ProjectEditorTarget: Identifiable {
    case create
    case edit(ProjectEditForm, id: Int, coverFilename: String?)

    var id: String {
        switch self {
        case .create: "create"
        case .edit(_, let id, _): "edit-\(id)"
        }
    }
}

/// Create / edit form for a project (name, link, parent, cover, color, targets,
/// tags, due date, priority, budget, status).
struct ProjectEditorSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    let target: ProjectEditorTarget
    let allProjects: [ProjectListEntry]
    let currency: String
    var onSaved: (ProjectDetail?) -> Void

    @State private var form = ProjectEditForm()
    @State private var runner = ActionRunner()
    @State private var loadedProjects: [ProjectListEntry] = []
    @State private var coverFilename: String?
    @State private var coverItem: PhotosPickerItem?
    @State private var coverBusy = false
    @State private var coverVersion = 0

    private var projectId: Int? {
        if case .edit(_, let id, _) = target { return id }
        return nil
    }
    private var isEdit: Bool { projectId != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $form.name)
                    TextField("Description", text: $form.description, axis: .vertical).lineLimit(2...5)
                    TextField("Link (https://…)", text: $form.url)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: {
                    if !form.urlIsValid { Text("The link must start with http:// or https://").foregroundStyle(.red) }
                }

                Section {
                    Picker("Parent Project", selection: $form.parentId) {
                        Text("None").tag(Int?.none)
                        ForEach(parentOptions) { p in Text(p.name).tag(Int?.some(p.id)) }
                    }
                } footer: {
                    Text("Nest this project under another one; its prints and costs roll up into the parent.")
                }

                if let projectId { coverSection(projectId) }

                Section("Color") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 36), spacing: 10)], spacing: 10) {
                        ForEach(ProjectPalette.colors, id: \.self) { hex in
                            Button { form.color = hex } label: {
                                Circle().fill(Color(hex: hex) ?? .gray)
                                    .frame(width: 32, height: 32)
                                    .overlay {
                                        if form.color.lowercased() == hex { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white) }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(hex)
                        }
                    }
                    .padding(.vertical, 4)
                    ColorPicker("Custom Color", selection: Binding(
                        get: { Color(hex: form.color) ?? .gray },
                        set: { form.color = "#" + $0.hexString.lowercased() }
                    ), supportsOpacity: false)
                }

                Section {
                    LabeledContent("Target Plates") {
                        TextField("Optional", text: $form.targetPlates).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Target Parts") {
                        TextField("Optional", text: $form.targetParts).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Copies per File") {
                        TextField("Optional", text: $form.targetSets).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("Targets")
                } footer: {
                    Text("Plates counts print jobs, parts counts printed objects. Copies per file tracks how many complete sets of the linked files are done.")
                }

                Section("Planning") {
                    TextField("Tags (comma separated)", text: $form.tags).textInputAutocapitalization(.never)
                    Toggle("Due Date", isOn: $form.hasDueDate.animation())
                    if form.hasDueDate {
                        DatePicker("Due", selection: $form.dueDate, displayedComponents: .date)
                    }
                    Picker("Priority", selection: $form.priority) {
                        ForEach(["low", "normal", "high", "urgent"], id: \.self) { Text(ProjectPalette.priorityLabel($0)).tag($0) }
                    }
                    LabeledContent("Budget (\(currency))") {
                        TextField("None", text: $form.budget).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    if isEdit {
                        Picker("Status", selection: $form.status) {
                            ForEach(["active", "completed", "archived"], id: \.self) { Text(ProjectPalette.statusLabel($0)).tag($0) }
                        }
                    }
                }
            }
            .navigationTitle(isEdit ? "Edit Project" : "New Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        // The cover image is saved as soon as it is picked.
                        if coverVersion > 0 { onSaved(nil) }
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEdit ? "Save" : "Create") { Task { await save() } }
                        .disabled(form.name.trimmingCharacters(in: .whitespaces).isEmpty || !form.urlIsValid || runner.isRunning)
                }
            }
            .actionAlerts(runner)
            .interactiveDismissDisabled(runner.isRunning)
            .task {
                if case .edit(let f, _, let cover) = target { form = f; coverFilename = cover }
                if allProjects.isEmpty, let list: [ProjectListEntry] = try? await session.client.get("projects/") {
                    loadedProjects = list
                }
            }
            .onChange(of: coverItem) { _, item in
                guard let item, let projectId else { return }
                Task { await uploadCover(item, projectId: projectId) }
            }
        }
    }

    /// Anything except this project and its own sub-projects (which would create a cycle).
    private var parentOptions: [ProjectListEntry] {
        let list = allProjects.isEmpty ? loadedProjects : allProjects
        guard let projectId else { return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
        var excluded: Set<Int> = [projectId]
        var changed = true
        while changed {
            changed = false
            for p in list where !excluded.contains(p.id) {
                if let parent = p.parentId, excluded.contains(parent) { excluded.insert(p.id); changed = true }
            }
        }
        return list.filter { !excluded.contains($0.id) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @ViewBuilder
    private func coverSection(_ projectId: Int) -> some View {
        Section("Cover Image") {
            HStack(spacing: 14) {
                Group {
                    if coverFilename != nil {
                        RemoteImage(path: "projects/\(projectId)/cover-image", reloadKey: "\(coverFilename ?? "")-\(coverVersion)")
                    } else {
                        ImagePlaceholder(systemImage: "photo")
                    }
                }
                .frame(width: 72, height: 72)
                .clipShape(.rect(cornerRadius: 10))
                .overlay { if coverBusy { ProgressView() } }

                VStack(alignment: .leading, spacing: 8) {
                    let pickerTitle = coverFilename == nil ? "Choose Photo" : "Replace Photo"
                    PhotosPicker(selection: $coverItem, matching: .images) {
                        Label(pickerTitle, systemImage: "photo.on.rectangle")
                    }
                    if coverFilename != nil {
                        Button(role: .destructive) { Task { await removeCover(projectId) } } label: {
                            Label("Remove", systemImage: "xmark.circle")
                        }
                    }
                }
                .buttonStyle(.borderless)
                .disabled(coverBusy)
            }
        }
    }

    private func uploadCover(_ item: PhotosPickerItem, projectId: Int) async {
        coverBusy = true
        defer { coverBusy = false; coverItem = nil }
        await runner.run(nil) {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.85) ?? data
            let result: ProjectUploadResult = try await session.client.upload("projects/\(projectId)/cover-image", files: [
                UploadFile(fileName: "cover.jpg", mimeType: "image/jpeg", data: jpeg),
            ])
            coverFilename = result.filename ?? "cover"
            coverVersion += 1
        }
    }

    private func removeCover(_ projectId: Int) async {
        coverBusy = true
        defer { coverBusy = false }
        await runner.run(nil) {
            try await session.client.call(.delete, "projects/\(projectId)/cover-image")
            coverFilename = nil
            coverVersion += 1
        }
    }

    private func save() async {
        var saved: ProjectDetail?
        await runner.run(nil) {
            if let projectId {
                saved = try await session.client.send(.patch, "projects/\(projectId)", body: form.body(isEdit: true))
            } else {
                saved = try await session.client.send(.post, "projects/", body: form.body(isEdit: false))
            }
        }
        if runner.errorMessage == nil {
            onSaved(saved)
            dismiss()
        }
    }
}
