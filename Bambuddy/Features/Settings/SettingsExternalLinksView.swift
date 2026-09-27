import SwiftUI

/// Custom links shown in the web interface's sidebar: list, open, create, edit, reorder, delete.
struct SettingsExternalLinksView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.openURL) private var openURL

    @State private var links: [SettingsExternalLink] = []
    @State private var hasLoaded = false
    @State private var loadError: String?
    @State private var runner = ActionRunner()
    @State private var editing: LinkEditTarget?
    @State private var deleting: SettingsExternalLink?

    private var canCreate: Bool { session.can("external_links:create") }
    private var canUpdate: Bool { session.can("external_links:update") }
    private var canDelete: Bool { session.can("external_links:delete") }

    var body: some View {
        content
            .navigationTitle("External Links")
            .toolbar {
                if canUpdate && links.count > 1 {
                    ToolbarItem(placement: .topBarTrailing) { EditButton() }
                }
                if canCreate {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { editing = .new } label: { Label("Add Link", systemImage: "plus") }
                    }
                }
            }
            .task { await load() }
            .refreshable { await load() }
            .actionAlerts(runner)
            .sheet(item: $editing) { target in
                SettingsExternalLinkEditor(link: target.link) { saved in
                    if let index = links.firstIndex(where: { $0.id == saved.id }) {
                        links[index] = saved
                    } else {
                        links.append(saved)
                    }
                    runner.successMessage = target.link == nil ? "Link added" : "Link saved"
                }
            }
            .confirmationDialog("Delete \(deleting?.name ?? "Link")?", isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting) { link in
                Button("Delete", role: .destructive) { Task { await delete(link) } }
            } message: { _ in
                Text("The link is removed from the sidebar for everyone.")
            }
    }

    @ViewBuilder private var content: some View {
        if !hasLoaded {
            if let loadError {
                ContentUnavailableView {
                    Label("Couldn't Load Links", systemImage: "exclamationmark.triangle")
                } description: { Text(loadError) } actions: {
                    Button("Try Again") { Task { await load() } }.buttonStyle(.bordered)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if links.isEmpty {
            ContentUnavailableView {
                Label("No External Links", systemImage: "link")
            } description: {
                Text("Add shortcuts to other tools — a slicer farm, a wiki, a shop — and they appear in the web interface's sidebar.")
            } actions: {
                if canCreate {
                    Button("Add Link") { editing = .new }.buttonStyle(.borderedProminent)
                }
            }
        } else {
            List {
                Section {
                    ForEach(links) { link in
                        row(link)
                    }
                    .onMove { source, destination in move(from: source, to: destination) }
                    .moveDisabled(!canUpdate)
                } footer: {
                    Text("Links appear in this order in the web interface's sidebar. Tap a link to open it.")
                }
            }
        }
    }

    private func row(_ link: SettingsExternalLink) -> some View {
        Button {
            if let url = URL(string: link.url) { openURL(url) }
        } label: {
            HStack(spacing: 12) {
                SettingsExternalLinkIconView(link: link)
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(link.name).foregroundStyle(.primary)
                    Text(URL(string: link.url)?.host() ?? link.url)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "arrow.up.forward.app").foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .tint(.primary)
        .swipeActions(edge: .trailing) {
            if canDelete {
                Button(role: .destructive) { deleting = link } label: { Label("Delete", systemImage: "trash") }
            }
            if canUpdate {
                Button { editing = .existing(link) } label: { Label("Edit", systemImage: "pencil") }.tint(.orange)
            }
        }
        .contextMenu {
            if let url = URL(string: link.url) {
                Button { openURL(url) } label: { Label("Open", systemImage: "safari") }
                Button { UIPasteboard.general.url = url } label: { Label("Copy URL", systemImage: "doc.on.doc") }
                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
            }
            if canUpdate {
                Button { editing = .existing(link) } label: { Label("Edit", systemImage: "pencil") }
            }
            if canDelete {
                Button(role: .destructive) { deleting = link } label: { Label("Delete", systemImage: "trash") }
            }
        }
    }

    // MARK: Actions

    private func load() async {
        do {
            links = try await session.client.get("external-links/")
            hasLoaded = true
            loadError = nil
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            if hasLoaded { runner.errorMessage = error.localizedDescription } else { loadError = error.localizedDescription }
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        links.move(fromOffsets: source, toOffset: destination)
        let ids = links.map(\.id)
        Task {
            await runner.run {
                do {
                    links = try await session.client.send(.put, "external-links/reorder", body: SettingsExternalLinkReorder(ids: ids))
                } catch {
                    await load()
                    throw error
                }
            }
        }
    }

    private func delete(_ link: SettingsExternalLink) async {
        await runner.run("Link deleted") {
            try await session.client.call(.delete, "external-links/\(link.id)")
            links.removeAll { $0.id == link.id }
        }
    }
}

private enum LinkEditTarget: Identifiable {
    case new
    case existing(SettingsExternalLink)

    var id: String {
        switch self {
        case .new: "new"
        case .existing(let link): "link-\(link.id)"
        }
    }

    var link: SettingsExternalLink? {
        if case .existing(let link) = self { return link }
        return nil
    }
}

/// A link's uploaded icon, or its preset symbol.
struct SettingsExternalLinkIconView: View {
    let link: SettingsExternalLink

    var body: some View {
        let symbol = SettingsExternalLinkIcons.symbol(for: link.icon)
        if let path = link.customIconPath {
            RemoteImage(path: path, contentMode: .fit, reloadKey: link.customIcon) {
                symbolTile(symbol)
            }
            .clipShape(.rect(cornerRadius: 7))
        } else {
            symbolTile(symbol)
        }
    }

    private func symbolTile(_ symbol: String) -> some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(Color.accentColor.opacity(0.15))
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.tint)
            }
    }
}
