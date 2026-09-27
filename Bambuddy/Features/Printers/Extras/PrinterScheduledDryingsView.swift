import SwiftUI

// MARK: Models

struct PrinterScheduledDrying: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var printerId: Int
    var amsId: Int
    var temp: Int
    var durationHours: Int
    var filament: String
    var rotateTray: Bool
    var startAfter: String?
    var status: String
    var waitingReason: String?
    var errorMessage: String?
    var createdAt: String?
    var startedAt: String?
    var completedAt: String?

    var waitingText: String? {
        switch waitingReason {
        case nil: return nil
        case "printer_offline": return "Waiting for the printer to come online"
        case "already_drying": return "Waiting: the AMS is already drying"
        case "printer_busy": return "Waiting for the printer to finish printing"
        case "ams_not_found": return "Waiting: AMS unit not found"
        case "ams_power_required": return "Waiting: the AMS needs its power adapter"
        case "ams_retract_filament": return "Waiting: retract filament from the AMS first"
        case "ams_blocked": return "Waiting: the AMS is busy"
        case "interrupted": return "Interrupted"
        default: return "Waiting (\(waitingReason!.replacingOccurrences(of: "_", with: " ")))"
        }
    }
}

struct PrinterScheduledDryingCreate: Codable, Sendable {
    var printerId: Int
    var amsId: Int
    var temp: Int
    var durationHours: Int
    var filament: String
    var rotateTray: Bool
    var startAfter: Date?

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(printerId, forKey: .printerId)
        try c.encode(amsId, forKey: .amsId)
        try c.encode(temp, forKey: .temp)
        try c.encode(durationHours, forKey: .durationHours)
        try c.encode(filament, forKey: .filament)
        try c.encode(rotateTray, forKey: .rotateTray)
        // Always send the key: null means "as soon as possible".
        try c.encode(startAfter, forKey: .startAfter)
    }
}

// MARK: List

struct PrinterScheduledDryingsView: View {
    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var store
    let printerId: Int

    @State private var loader = Loader<[PrinterScheduledDrying]>()
    @State private var runner = ActionRunner()
    @State private var showCreate = false
    @State private var pendingCancel: PrinterScheduledDrying?

    private var client: APIClient { session.client }
    private var units: [AMSUnit] { store.statuses[printerId]?.ams ?? [] }
    private var canControl: Bool { session.can("printers:control") }
    private var supportsDrying: Bool { store.statuses[printerId]?.supportsDrying ?? false }

    var body: some View {
        LoadingContent(loader: loader, retry: load) { items in
            List {
                if !supportsDrying {
                    Section {
                        Label("This printer's AMS units don't support remote drying.", systemImage: "info.circle").foregroundStyle(.secondary)
                    }
                }
                if items.isEmpty {
                    ContentUnavailableView("No Scheduled Dryings", systemImage: "sun.max",
                                           description: Text("Schedule an AMS drying cycle to start later or after the current print."))
                }
                ForEach(items) { item in
                    row(item)
                        .swipeActions {
                            if canControl {
                                Button(role: .destructive) { pendingCancel = item } label: {
                                    Label(item.status == "failed" ? "Dismiss" : "Cancel", systemImage: "xmark")
                                }
                            }
                        }
                        .contextMenu {
                            if canControl {
                                Button(role: .destructive) { pendingCancel = item } label: {
                                    Label(item.status == "failed" ? "Dismiss" : "Cancel Drying", systemImage: "xmark")
                                }
                            }
                        }
                }
            }
        }
        .navigationTitle("Scheduled Drying")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canControl && supportsDrying {
                ToolbarItem(placement: .primaryAction) {
                    Button { showCreate = true } label: { Image(systemName: "plus") }.accessibilityLabel("Schedule Drying")
                }
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await load()
            }
        }
        .actionAlerts(runner)
        .sheet(isPresented: $showCreate) {
            PrinterScheduleDryingSheet(printerId: printerId, units: dryableUnits) { await load() }
        }
        .confirmationDialog(pendingCancel?.status == "failed" ? "Dismiss this entry?" : "Cancel this drying?",
                            isPresented: Binding(get: { pendingCancel != nil }, set: { if !$0 { pendingCancel = nil } }), titleVisibility: .visible) {
            if let item = pendingCancel {
                Button(item.status == "failed" ? "Dismiss" : "Cancel Drying", role: .destructive) {
                    Task { await runner.run { try await client.call(.delete, "scheduled-dryings/\(item.id)"); await load() } }
                }
            }
        } message: {
            if pendingCancel?.status == "running" { Text("Drying that is already running will be stopped.") }
        }
    }

    private var dryableUnits: [AMSUnit] {
        let filtered = units.filter { ["n3f", "n3s"].contains($0.moduleType ?? "") || $0.isAmsHt == true }
        return filtered.isEmpty ? units : filtered
    }

    @ViewBuilder
    private func row(_ item: PrinterScheduledDrying) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(unitLabel(item.amsId)).font(.headline)
                Spacer()
                StatusBadge(text: item.status.capitalized, color: color(item.status))
            }
            Text("\(item.temp)°C for \(item.durationHours) h\(item.filament.isEmpty ? "" : " · \(item.filament)")\(item.rotateTray ? " · rotate spools" : "")")
                .font(.subheadline)
            if item.status == "pending" {
                Text(item.startAfter.map { "Starts \(Fmt.date($0))" } ?? "Starts as soon as possible")
                    .font(.caption).foregroundStyle(.secondary)
                if let waiting = item.waitingText { Text(waiting).font(.caption).foregroundStyle(.orange) }
            } else if item.status == "running", let started = item.startedAt {
                Text("Started \(Fmt.relative(started))").font(.caption).foregroundStyle(.secondary)
            } else if item.status == "failed" {
                Text(item.errorMessage ?? "Failed").font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func unitLabel(_ amsId: Int) -> String {
        units.first { $0.id == amsId }?.label ?? (amsId >= 128 ? "AMS HT \(amsId - 127)" : "AMS \(amsId + 1)")
    }

    private func color(_ status: String) -> Color {
        switch status {
        case "running": return .orange
        case "failed": return .red
        case "pending": return .blue
        default: return .secondary
        }
    }

    private func load() async {
        await loader.load { try await client.get("scheduled-dryings", query: ["printer_id": .int(printerId)]) }
    }
}

// MARK: Create

private struct PrinterScheduleDryingSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let printerId: Int
    let units: [AMSUnit]
    let onCreated: () async -> Void

    enum StartMode: String, CaseIterable, Identifiable { case asap, delay, time; var id: String { rawValue } }

    @State private var amsId = 0
    @State private var filament = "PLA"
    @State private var temp = 55
    @State private var hours = 8
    @State private var rotate = false
    @State private var mode: StartMode = .delay
    @State private var delayMinutes = 120
    @State private var startAt = Date().addingTimeInterval(3600)
    @State private var runner = ActionRunner()

    private static let presets: [(String, Int, Int)] = [
        ("PLA", 55, 8), ("PETG", 65, 8), ("TPU", 65, 8), ("ABS", 80, 8), ("ASA", 80, 8),
        ("PA", 85, 12), ("PC", 80, 8), ("PVA", 60, 8),
    ]
    private static let delays = [30, 60, 120, 240, 480, 720, 1440]

    var body: some View {
        NavigationStack {
            Form {
                if units.count > 1 {
                    Picker("AMS Unit", selection: $amsId) {
                        ForEach(units) { Text($0.label).tag($0.id) }
                    }
                }
                Section("Filament") {
                    Picker("Material", selection: $filament) {
                        ForEach(Self.presets, id: \.0) { Text($0.0).tag($0.0) }
                    }
                    Stepper(value: $temp, in: 45...85, step: 5) { LabeledContent("Temperature", value: "\(temp) °C") }
                    Stepper(value: $hours, in: 1...24) { LabeledContent("Duration", value: "\(hours) h") }
                    Toggle("Rotate Spools", isOn: $rotate)
                }
                Section("Start") {
                    Picker("Start", selection: $mode) {
                        Text("ASAP").tag(StartMode.asap)
                        Text("After Delay").tag(StartMode.delay)
                        Text("At Time").tag(StartMode.time)
                    }
                    .pickerStyle(.segmented)
                    switch mode {
                    case .asap:
                        Text("Starts as soon as the printer is idle and the AMS is ready.").font(.footnote).foregroundStyle(.secondary)
                    case .delay:
                        Picker("Delay", selection: $delayMinutes) {
                            ForEach(Self.delays, id: \.self) { Text(Fmt.minutes($0)).tag($0) }
                        }
                    case .time:
                        DatePicker("Start At", selection: $startAt, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    }
                }
            }
            .navigationTitle("Schedule Drying")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Schedule") { Task { await create() } }.disabled(runner.isRunning)
                }
            }
            .onChange(of: filament) { _, f in
                if let p = Self.presets.first(where: { $0.0 == f }) { temp = p.1; hours = p.2 }
            }
            .onAppear {
                amsId = units.first?.id ?? 0
                if let f = units.first?.dryFilament, Self.presets.contains(where: { $0.0 == f }) { filament = f }
            }
            .actionAlerts(runner)
        }
    }

    private func create() async {
        let start: Date? = switch mode {
        case .asap: nil
        case .delay: Date().addingTimeInterval(Double(delayMinutes) * 60)
        case .time: startAt
        }
        let body = PrinterScheduledDryingCreate(printerId: printerId, amsId: amsId, temp: temp, durationHours: hours,
                                                filament: filament, rotateTray: rotate, startAfter: start)
        await runner.run {
            let _: PrinterScheduledDrying = try await session.client.send(.post, "scheduled-dryings", body: body)
            await onCreated()
            dismiss()
        }
    }
}
