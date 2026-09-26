import SwiftUI

struct PrintersView: View {
    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var store
    @Environment(LiveUpdates.self) private var live
    @State private var showAdd = false
    @State private var path = NavigationPath()

    private let columns = [GridItem(.adaptive(minimum: 320, maximum: 520), spacing: 16)]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                if !live.isConnected && !store.printers.isEmpty {
                    Label("Live updates reconnecting…", systemImage: "bolt.horizontal.circle")
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(store.printers) { printer in
                        NavigationLink(value: printer.id) {
                            PrinterCard(printer: printer, status: store.statuses[printer.id])
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .overlay {
                if store.isLoading {
                    ProgressView()
                } else if store.printers.isEmpty {
                    ContentUnavailableView {
                        Label("No Printers", systemImage: "printer")
                    } description: {
                        Text(store.error ?? "Add a Bambu Lab printer to get started.")
                    } actions: {
                        if session.can("printers:create") {
                            Button("Add Printer") { showAdd = true }.buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
            .refreshable { await store.refresh() }
            .navigationTitle("Printers")
            .navigationDestination(for: Int.self) { id in
                PrinterDetailView(printerId: id)
            }
            .toolbar {
                if session.can("printers:create") {
                    ToolbarItem(placement: .primaryAction) {
                        Button { showAdd = true } label: { Label("Add Printer", systemImage: "plus") }
                    }
                }
            }
            .sheet(isPresented: $showAdd) {
                PrinterEditView(printer: nil) { Task { await store.refresh() } }
            }
        }
    }
}

struct PrinterCard: View {
    let printer: Printer
    let status: PrinterStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(printer.name).font(.headline)
                    Text([printer.model, printer.location].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                PrinterStateBadge(status: status)
            }

            HStack(spacing: 12) {
                RemoteImage(path: status?.isActiveJob == true ? status?.coverUrl : nil, contentMode: .fit, reloadKey: status?.gcodeFile, systemImage: "cube")
                    .frame(width: 84, height: 84)
                    .clipShape(.rect(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 6) {
                    if let status, status.isActiveJob {
                        Text(status.jobName ?? "Printing").font(.subheadline.weight(.medium)).lineLimit(2)
                        ProgressView(value: (status.progress ?? 0) / 100)
                            .tint(status.isPaused ? .orange : .accentColor)
                        HStack {
                            Text(Fmt.percent(status.progress))
                            Spacer()
                            if let l = status.layerNum, let t = status.totalLayers, t > 0 { Text("Layer \(l)/\(t)") }
                            Spacer()
                            Label(Fmt.minutes(status.remainingTime), systemImage: "clock")
                        }
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    } else {
                        Text(status?.connected == false ? "Printer is offline" : "Ready")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if let stage = status?.stgCurName, !stage.isEmpty, status?.stgCur ?? 0 > 0 {
                            Text(stage).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let status {
                HStack(spacing: 14) {
                    TempChip(systemImage: "flame", value: status.temp("nozzle"), target: status.temp("nozzle_target"))
                    if status.isDualNozzle {
                        TempChip(systemImage: "flame.fill", value: status.temp("nozzle_2"), target: status.temp("nozzle_2_target"))
                    }
                    TempChip(systemImage: "square.3.layers.3d.bottom.filled", value: status.temp("bed"), target: status.temp("bed_target"))
                    if status.hasChamberTemp {
                        TempChip(systemImage: "cube.transparent", value: status.temp("chamber"), target: nil)
                    }
                    Spacer()
                    if !(status.hmsErrors ?? []).isEmpty {
                        Label("\(status.hmsErrors!.count)", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                    }
                }
                AMSStrip(status: status)
            }
        }
        .padding()
        .background(.background.secondary, in: .rect(cornerRadius: 18))
        .contentShape(.rect(cornerRadius: 18))
    }
}

struct PrinterStateBadge: View {
    let status: PrinterStatus?
    var body: some View {
        StatusBadge(text: status?.stateLabel ?? "…", color: color)
    }
    private var color: Color {
        guard let status, status.connected else { return .gray }
        switch status.state {
        case "RUNNING", "PREPARE", "SLICING": return .blue
        case "PAUSE": return .orange
        case "FAILED": return .red
        case "FINISH": return .green
        default: return .green
        }
    }
}

struct TempChip: View {
    let systemImage: String
    let value: Double?
    let target: Double?
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage).foregroundStyle(isHeating ? .orange : .secondary)
            Text(Fmt.temp(value))
            if let target, target > 0 { Text("/\(Int(target))").foregroundStyle(.secondary) }
        }
        .font(.caption.monospacedDigit())
    }
    private var isHeating: Bool { (target ?? 0) > 0 }
}

/// Compact row of filament swatches for all AMS units.
struct AMSStrip: View {
    let status: PrinterStatus
    var body: some View {
        let units = status.ams ?? []
        if !units.isEmpty || !(status.vtTray ?? []).isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(units) { unit in
                        HStack(spacing: 4) {
                            ForEach(unit.tray ?? []) { tray in
                                ColorSwatch(hex: tray.isEmpty ? nil : tray.trayColor, size: 18)
                                    .overlay {
                                        if status.trayNow == unit.globalTrayId(tray.id) {
                                            Circle().strokeBorder(Color.accentColor, lineWidth: 2.5).frame(width: 24, height: 24)
                                        }
                                    }
                            }
                        }
                        .padding(5)
                        .background(.quaternary.opacity(0.6), in: .capsule)
                    }
                    ForEach(status.vtTray ?? []) { tray in
                        if !tray.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.turn.down.right").font(.caption2)
                                ColorSwatch(hex: tray.trayColor, size: 18)
                            }
                            .padding(5)
                            .background(.quaternary.opacity(0.6), in: .capsule)
                        }
                    }
                }
            }
        }
    }
}
