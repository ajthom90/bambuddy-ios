import SwiftUI

struct AMSCard: View {
    @Environment(AppSession.self) private var session
    let printerId: Int
    let status: PrinterStatus?
    let runner: ActionRunner
    @State private var dryingUnit: AMSUnit?
    @State private var configuring: SlotRef?

    struct SlotRef: Identifiable, Hashable {
        let amsId: Int
        let trayId: Int
        let tray: AMSTray
        var id: String { "\(amsId)-\(trayId)" }
    }

    private var client: APIClient { session.client }
    private var canControl: Bool { session.can("printers:control") && status?.connected == true }

    var body: some View {
        DetailCard(title: "Filament", systemImage: "circle.hexagonpath") {
            if let status {
                let units = status.ams ?? []
                if units.isEmpty && (status.vtTray ?? []).allSatisfy(\.isEmpty) {
                    Text("No AMS detected.").foregroundStyle(.secondary)
                }
                ForEach(units) { unit in
                    unitView(unit, status: status)
                }
                ForEach(status.vtTray ?? []) { tray in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("External Spool").font(.subheadline.weight(.semibold))
                        slotButton(tray: tray, amsId: 255, trayId: tray.id == 254 ? 0 : 1, globalId: tray.id, status: status)
                    }
                }
                if canControl, status.trayNow != nil, status.trayNow != 255, !status.isActiveJob {
                    Button { Task { await runner.run("Unloading filament") { try await client.call(.post, "printers/\(printerId)/ams/unload") } } } label: {
                        Label("Unload Filament", systemImage: "eject")
                    }
                    .buttonStyle(.bordered)
                }
                if let backup = status.amsFilamentBackup, canControl {
                    Toggle(isOn: Binding(get: { backup }, set: { on in
                        Task { await runner.run { try await client.call(.post, "printers/\(printerId)/ams-backup", query: ["enabled": .bool(on)]) } }
                    })) { Label("AMS Filament Backup", systemImage: "arrow.triangle.2.circlepath") }
                }
            } else {
                ProgressView()
            }
        }
        .sheet(item: $dryingUnit) { unit in
            DryingSheet(printerId: printerId, unit: unit, runner: runner)
        }
        .sheet(item: $configuring) { ref in
            ConfigureSlotView(printerId: printerId, amsId: ref.amsId, trayId: ref.trayId, tray: ref.tray)
        }
    }

    @ViewBuilder
    private func unitView(_ unit: AMSUnit, status: PrinterStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(unit.label).font(.subheadline.weight(.semibold))
                if let h = unit.humidity { Label("\(h)%", systemImage: "humidity").font(.caption).foregroundStyle(humidityColor(h)) }
                if let t = unit.temp { Label(Fmt.temp(t), systemImage: "thermometer").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if unit.isDrying {
                    StatusBadge(text: "Drying \(unit.dryTime.map { Fmt.minutes($0) } ?? "")", color: .orange)
                }
                if status.supportsDrying == true, canControl {
                    Menu {
                        if unit.isDrying {
                            Button("Stop Drying", role: .destructive) {
                                Task { await runner.run { try await client.call(.post, "printers/\(printerId)/drying/stop", query: ["ams_id": .int(unit.id)]) } }
                            }
                        } else {
                            Button("Start Drying…") { dryingUnit = unit }
                        }
                    } label: { Image(systemName: "sun.max").padding(4) }
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8)], spacing: 8) {
                ForEach(unit.tray ?? []) { tray in
                    slotButton(tray: tray, amsId: unit.id, trayId: tray.id, globalId: unit.globalTrayId(tray.id), status: status)
                }
            }
        }
    }

    private func humidityColor(_ h: Int) -> Color { h <= 40 ? .green : h <= 60 ? .orange : .red }

    @ViewBuilder
    private func slotButton(tray: AMSTray, amsId: Int, trayId: Int, globalId: Int, status: PrinterStatus) -> some View {
        let active = status.trayNow == globalId
        Menu {
            Section(tray.isEmpty ? "Empty Slot" : "\(tray.displayName) · \(tray.trayType ?? "")") {
                if let min = tray.nozzleTempMin, let max = tray.nozzleTempMax, max > 0 { Text("Nozzle \(min)–\(max)°C") }
                if let k = tray.k { Text("K = \(k.formatted(.number.precision(.fractionLength(3))))") }
                if let remain = tray.remain, remain >= 0 { Text("\(remain)% remaining") }
            }
            if canControl {
                if !status.isActiveJob, !tray.isEmpty, !active {
                    Button { Task { await runner.run("Loading filament") { try await client.call(.post, "printers/\(printerId)/ams/load", query: ["tray_id": .int(globalId)]) } } } label: {
                        Label("Load", systemImage: "arrow.down.to.line")
                    }
                }
                if active, !status.isActiveJob {
                    Button { Task { await runner.run("Unloading filament") { try await client.call(.post, "printers/\(printerId)/ams/unload", query: ["tray_id": .int(globalId)]) } } } label: {
                        Label("Unload", systemImage: "eject")
                    }
                }
                Button { configuring = SlotRef(amsId: amsId, trayId: trayId, tray: tray) } label: {
                    Label("Configure Slot…", systemImage: "slider.horizontal.3")
                }
                if amsId < 255, session.can("printers:ams_rfid") {
                    Button { Task { await runner.run("Re-reading RFID") { try await client.call(.post, "printers/\(printerId)/ams/\(amsId)/slot/\(trayId)/refresh") } } } label: {
                        Label("Re-read RFID", systemImage: "sensor.tag.radiowaves.forward")
                    }
                }
                Button(role: .destructive) { Task { await runner.run("Slot reset") { try await client.call(.post, "printers/\(printerId)/ams/\(amsId)/tray/\(trayId)/reset") } } } label: {
                    Label("Reset Slot", systemImage: "arrow.counterclockwise")
                }
            }
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    ColorSwatch(hex: tray.isEmpty ? nil : tray.trayColor, size: 36)
                    if active { Circle().strokeBorder(Color.accentColor, lineWidth: 3).frame(width: 44, height: 44) }
                }
                .frame(height: 44)
                Text(tray.isEmpty ? "Empty" : (tray.trayType ?? "")).font(.caption2.weight(.medium)).lineLimit(1)
                if let remain = tray.remain, remain >= 0, !tray.isEmpty {
                    ProgressView(value: Double(remain) / 100).frame(width: 40).tint(remain < 15 ? .red : .accentColor)
                } else {
                    Text(tray.isEmpty || tray.displayName == tray.trayType ? " " : tray.displayName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(active ? Color.accentColor.opacity(0.12) : Color.clear, in: .rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

struct DryingSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let printerId: Int
    let unit: AMSUnit
    let runner: ActionRunner
    @State private var temp: Double = 55
    @State private var hours: Double = 8
    @State private var filament = "PLA"
    @State private var rotate = false

    private static let presets: [(String, Double, Double)] = [
        ("PLA", 55, 8), ("PETG", 65, 8), ("ABS", 80, 8), ("ASA", 80, 8), ("TPU", 70, 8), ("PA", 85, 12), ("PC", 80, 8), ("PVA", 55, 8),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Filament") {
                    Picker("Preset", selection: $filament) {
                        ForEach(Self.presets, id: \.0) { Text($0.0).tag($0.0) }
                    }
                    .onChange(of: filament) { _, f in
                        if let p = Self.presets.first(where: { $0.0 == f }) { temp = p.1; hours = p.2 }
                    }
                }
                Section("Settings") {
                    Stepper("Temperature: \(Int(temp))°C", value: $temp, in: 40...(unit.isAmsHt == true ? 90 : 65), step: 5)
                    Stepper("Duration: \(Int(hours)) h", value: $hours, in: 1...24)
                    Toggle("Rotate Spool", isOn: $rotate)
                }
            }
            .navigationTitle("Dry \(unit.label)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        Task {
                            await runner.run("Drying started") {
                                try await session.client.call(.post, "printers/\(printerId)/drying/start", query: [
                                    "ams_id": .int(unit.id), "temp": .int(Int(temp)), "duration": .int(Int(hours)),
                                    "filament": .string(filament), "rotate_tray": .bool(rotate),
                                ])
                            }
                            dismiss()
                        }
                    }
                }
            }
            .onAppear { if let f = unit.dryFilament, !f.isEmpty { filament = f } }
        }
        .presentationDetents([.medium])
    }
}
