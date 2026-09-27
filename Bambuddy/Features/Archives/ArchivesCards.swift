import SwiftUI

/// Grid card for an archive (thumbnail, badges, key stats).
struct ArchivesCard: View {
    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var printers
    @Environment(ArchivesLookups.self) private var lookups
    let archive: ArchivesRecord
    let actions: ArchivesActions
    var selecting = false
    var isSelected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            thumbnail
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.headline).lineLimit(2)
                    Spacer(minLength: 4)
                    Text("#\(archive.id)").font(.caption2).foregroundStyle(.tertiary)
                }
                ArchivesMetaLine(archive: archive)
                ArchivesStatsGrid(archive: archive)
                if !archive.materials.isEmpty || !archive.colors.isEmpty {
                    HStack(spacing: 6) {
                        Text(archive.materials.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        ArchivesColorDots(colors: archive.colors, size: 11)
                    }
                }
                if !archive.tagList.isEmpty || !(archive.notes ?? "").isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        if !(archive.notes ?? "").isEmpty {
                            Image(systemName: "note.text").font(.caption).foregroundStyle(.blue)
                        }
                        ArchivesTagChips(tags: archive.tagList)
                    }
                }
                Spacer(minLength: 0)
                Divider()
                HStack {
                    Text(Fmt.date(archive.createdAt)).lineLimit(1)
                    Spacer()
                    if let user = archive.createdByUsername {
                        Label(user, systemImage: "person").labelStyle(.titleAndIcon).lineLimit(1)
                    }
                    Text(Fmt.bytes(archive.fileSize))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .background(.background.secondary, in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
        }
        .contentShape(.rect(cornerRadius: 16))
    }

    private var title: String {
        if let plate = archive.plateId, plate > 1 { return "\(archive.displayName) — Plate \(plate)" }
        return archive.displayName
    }

    private var thumbnail: some View {
        Color.clear
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay { ArchivesThumbnail(archive: archive) }
            .background(Color(.tertiarySystemFill))
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16))
            .overlay(alignment: .topLeading) {
                HStack(spacing: 4) {
                    if selecting {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, isSelected ? Color.accentColor : .black.opacity(0.35))
                    }
                    if archive.isFailed {
                        StatusBadge(text: ArchivesVocabulary.statusLabel(archive.status), color: .white)
                            .background(.red.opacity(0.85), in: .capsule)
                    }
                    if let seq = archive.duplicateSequence, archive.isDuplicate {
                        StatusBadge(text: seq > 0 ? "#\(seq)" : "+\(archive.duplicateCount ?? 0)", color: .white)
                            .background(.purple.opacity(0.85), in: .capsule)
                    }
                }
                .padding(8)
            }
            .overlay(alignment: .topTrailing) {
                if !selecting {
                    Button {
                        Task { await actions.toggleFavorite(archive, client: session.client) }
                    } label: {
                        Image(systemName: archive.favorite ? "star.fill" : "star")
                            .foregroundStyle(archive.favorite ? .yellow : .white)
                            .padding(7)
                            .background(.black.opacity(0.4), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .disabled(!ArchivesPermissions.canUpdate(session, archive))
                    .accessibilityLabel(archive.favorite ? "Remove from favorites" : "Add to favorites")
                    .padding(8)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 6) {
                    if !archive.photoNames.isEmpty { mediaIcon("camera.fill", count: archive.photoNames.count) }
                    if archive.timelapsePath != nil { mediaIcon("film.fill") }
                    if archive.source3mfPath != nil { mediaIcon("doc.badge.gearshape.fill") }
                    if archive.f3dPath != nil { mediaIcon("cube.transparent.fill") }
                }
                .padding(8)
            }
    }

    private func mediaIcon(_ name: String, count: Int = 0) -> some View {
        HStack(spacing: 2) {
            Image(systemName: name)
            if count > 1 { Text("\(count)") }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(.black.opacity(0.5), in: .capsule)
    }
}

/// Compact list row for an archive.
struct ArchivesRow: View {
    let archive: ArchivesRecord
    var selecting = false
    var isSelected = false

    var body: some View {
        HStack(spacing: 12) {
            if selecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            ArchivesThumbnail(archive: archive)
                .frame(width: 64, height: 64)
                .background(Color(.tertiarySystemFill))
                .clipShape(.rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(archive.displayName).font(.headline).lineLimit(1)
                    if archive.favorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) }
                }
                ArchivesMetaLine(archive: archive, compact: true)
                HStack(spacing: 10) {
                    if let t = archive.actualTimeSeconds ?? archive.printTimeSeconds, t > 0 {
                        Label(ArchivesStyle.duration(t), systemImage: "clock")
                    }
                    if let g = archive.filamentUsedGrams, g > 0 {
                        Label(Fmt.grams(g), systemImage: "scalemass")
                    }
                    ArchivesColorDots(colors: archive.colors, size: 9)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                Text(Fmt.date(archive.createdAt, style: .dateTime.month(.abbreviated).day().year()))
                Text(Fmt.bytes(archive.fileSize))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// "Printer · type · project · runs" line with badges.
struct ArchivesMetaLine: View {
    @Environment(PrinterStore.self) private var printers
    @Environment(ArchivesLookups.self) private var lookups
    let archive: ArchivesRecord
    var compact = false

    var body: some View {
        HStack(spacing: 6) {
            Text(printerName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            StatusBadge(text: archive.isSliced ? "G-code" : "Source", color: archive.isSliced ? .green : .orange)
            if !compact, archive.status != "completed", !archive.isFailed, let status = archive.status {
                ArchivesStatusBadge(status: status)
            }
            if compact, archive.isFailed { ArchivesStatusBadge(status: archive.status) }
            if let project = archive.projectName {
                StatusBadge(text: project, color: Color(hex: lookups.project(archive.projectId)?.color) ?? .gray)
                    .lineLimit(1)
            }
            if let runs = archive.runCount, runs > 1 {
                StatusBadge(text: "\(runs) prints", color: .orange)
            }
        }
    }

    private var printerName: String {
        if let id = archive.printerId { return printers.printer(id)?.name ?? "Unknown printer" }
        return archive.slicedForModel ?? "No printer"
    }
}

/// Time / filament / cost / layers summary used on cards.
struct ArchivesStatsGrid: View {
    @Environment(ArchivesLookups.self) private var lookups
    let archive: ArchivesRecord

    var body: some View {
        let items = entries
        if !items.isEmpty {
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 4) {
                ForEach(items, id: \.0) { item in
                    Label {
                        Text(item.1).lineLimit(1)
                    } icon: {
                        Image(systemName: item.0)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var entries: [(String, String)] {
        var out: [(String, String)] = []
        if let t = archive.actualTimeSeconds ?? archive.printTimeSeconds, t > 0 {
            var text = ArchivesStyle.duration(t)
            if let acc = archive.timeAccuracy, archive.actualTimeSeconds != nil {
                let delta = Int((acc - 100).rounded())
                text += " (\(delta > 0 ? "+" : "")\(delta)%)"
            }
            out.append(("clock", text))
        }
        if let g = archive.filamentUsedGrams, g > 0 { out.append(("scalemass", ArchivesStyle.gramsPrecise(g))) }
        if let c = archive.cost { out.append(("dollarsign.circle", lookups.money(c))) }
        if let e = archive.energyCost { out.append(("bolt", lookups.money(e))) }
        if archive.totalLayers != nil || archive.layerHeight != nil {
            let parts = [archive.totalLayers.map { "\($0) layers" }, archive.layerHeight.map { "\(Fmt.number($0, digits: 2)) mm" }].compactMap { $0 }
            out.append(("square.stack.3d.up", parts.joined(separator: " · ")))
        }
        if let n = archive.objectCount, n > 0 { out.append(("cube", n == 1 ? "1 object" : "\(n) objects")) }
        if let model = archive.slicedForModel { out.append(("printer", model)) }
        return out
    }
}
