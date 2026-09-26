import SwiftUI

/// Saved project templates: start a new project from one, open or delete it.
struct ProjectTemplatesView: View {
    @Environment(AppSession.self) private var session
    @State private var loader = Loader<[ProjectListEntry]>()
    @State private var runner = ActionRunner()
    @State private var useTemplate: ProjectListEntry?
    @State private var newName = ""
    @State private var pendingDelete: ProjectListEntry?
    @State private var createdProjectId: Int?

    var body: some View {
        LoadingContent(loader: loader, retry: load) { templates in
            List {
                if templates.isEmpty {
                    ContentUnavailableView("No Templates", systemImage: "doc.on.doc",
                                           description: Text("Open a project and choose “Save as Template” to reuse its targets, parts list and settings."))
                }
                ForEach(templates) { template in
                    NavigationLink(value: ProjectsRoute.project(template.id)) {
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 8).fill(ProjectPalette.color(template.color).gradient)
                                .frame(width: 36, height: 36)
                                .overlay { Image(systemName: "doc.on.doc").foregroundStyle(.white) }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(template.name)
                                let details = [
                                    template.targetCount.map { "\($0) plates" },
                                    template.targetPartsCount.map { "\($0) parts" },
                                    template.description,
                                ].compactMap { $0 }.filter { !$0.isEmpty }
                                if !details.isEmpty {
                                    Text(details.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            if session.can("projects:create") {
                                Button("Use") { newName = template.name; useTemplate = template }
                                    .buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }
                    .swipeActions {
                        if session.can("projects:delete") {
                            Button(role: .destructive) { pendingDelete = template } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
            }
        }
        .navigationTitle("Templates")
        .refreshable { await load() }
        .task { await load() }
        .navigationDestination(item: $createdProjectId) { ProjectDetailView(projectId: $0) }
        .alert("New Project", isPresented: Binding(get: { useTemplate != nil }, set: { if !$0 { useTemplate = nil } })) {
            TextField("Project name", text: $newName)
            Button("Create") { if let t = useTemplate { Task { await create(from: t) } } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Creates a project with this template's settings and parts list.")
        }
        .confirm("Delete Template?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                 message: pendingDelete.map { "“\($0.name)” will be deleted. Projects created from it are not affected." }) {
            if let t = pendingDelete { Task { await delete(t) } }
        }
        .actionAlerts(runner)
    }

    private func load() async {
        await loader.load { try await session.client.get("projects/templates") }
    }

    private func create(from template: ProjectListEntry) async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        await runner.run("Project created") {
            let project: ProjectDetail = try await session.client.send(.post, "projects/from-template/\(template.id)", query: ["name": .of(name.isEmpty ? nil : name)])
            createdProjectId = project.id
        }
    }

    private func delete(_ template: ProjectListEntry) async {
        await runner.run("Template deleted") {
            try await session.client.call(.delete, "projects/\(template.id)")
        }
        await load()
    }
}
