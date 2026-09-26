import SwiftUI

// MARK: Temperatures

struct TemperaturesCard: View {
    @Environment(AppSession.self) private var session
    let printerId: Int
    let status: PrinterStatus?
    let runner: ActionRunner
    @State private var editing: TempTarget?

    struct TempTarget: Identifiable {
        let id: String
        let title: String
        let path: String
        var query: [String: QueryValue?] = [:]
        let current: Double
        let range: ClosedRange<Double>
    }

    var body: some View {
        DetailCard(title: "Temperatures", systemImage: "thermometer.medium") {
            if let status {
                let canControl = session.can("printers:control") && status.connected
                if status.isDualNozzle {
                    tempRow("Left Nozzle", "flame", status.temp("nozzle_2"), status.temp("nozzle_2_target"), canControl,
                            TempTarget(id: "n1", title: "Left Nozzle", path: "temperature/nozzle", query: ["nozzle": .int(1)], current: status.temp("nozzle_2_target") ?? 0, range: 0...320))
                    tempRow("Right Nozzle", "flame", status.temp("nozzle"), status.temp("nozzle_target"), canControl,
                            TempTarget(id: "n0", title: "Right Nozzle", path: "temperature/nozzle", query: ["nozzle": .int(0)], current: status.temp("nozzle_target") ?? 0, range: 0...320))
                } else {
                    tempRow("Nozzle", "flame", status.temp("nozzle"), status.temp("nozzle_target"), canControl,
                            TempTarget(id: "n0", title: "Nozzle", path: "temperature/nozzle", query: ["nozzle": .int(0)], current: status.temp("nozzle_target") ?? 0, range: 0...320))
                }
                tempRow("Bed", "square.3.layers.3d.bottom.filled", status.temp("bed"), status.temp("bed_target"), canControl,
                        TempTarget(id: "bed", title: "Bed", path: "temperature/bed", current: status.temp("bed_target") ?? 0, range: 0...120))
                if status.hasChamberTemp {
                    tempRow("Chamber", "cube.transparent", status.temp("chamber"), status.supportsChamberHeater == true ? status.temp("chamber_target") : nil,
                            canControl && status.supportsChamberHeater == true,
                            TempTarget(id: "chamber", title: "Chamber", path: "temperature/chamber", current: status.temp("chamber_target") ?? 0, range: 0...65))
                }
            } else {
                ProgressView()
            }
        }
        .sheet(item: $editing) { target in
            TemperatureSheet(target: target) { value in
                var q = target.query
                q["target"] = .int(Int(value))
                await runner.run { try await session.client.call(.post, "printers/\(printerId)/\(target.path)", query: q) }
            }
            .presentationDetents([.height(280)])
        }
    }

    @ViewBuilder
    private func tempRow(_ title: String, _ icon: String, _ value: Double?, _ target: Double?, _ editable: Bool, _ t: TempTarget) -> some View {
        Button {
            editing = t
        } label: {
            HStack {
                Label(title, systemImage: icon).foregroundStyle(.primary)
                Spacer()
                Text(Fmt.temp(value)).font(.title3.weight(.semibold)).monospacedDigit()
                if let target {
                    Text("→ \(Int(target))°").foregroundStyle(target > 0 ? .orange : .secondary).monospacedDigit()
                }
                if editable { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
            }
        }
        .disabled(!editable)
        .buttonStyle(.plain)
    }
}

struct TemperatureSheet: View {
    let target: TemperaturesCard.TempTarget
    let apply: (Double) async -> Void
    @State private var value: Double = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("\(Int(value))°C").font(.system(size: 48, weight: .bold, design: .rounded)).monospacedDigit()
                Slider(value: $value, in: target.range, step: 1)
                HStack {
                    Button("Off") { value = 0 }.buttonStyle(.bordered)
                    Stepper("", value: $value, in: target.range, step: 5).labelsHidden()
                }
            }
            .padding()
            .navigationTitle(target.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set") { Task { await apply(value); dismiss() } }
                }
            }
            .onAppear { value = target.current }
        }
    }
}

// MARK: Controls

struct ControlsCard: View {
    @Environment(AppSession.self) private var session
    let printerId: Int
    let status: PrinterStatus?
    let runner: ActionRunner
    @State private var jogStep: Double = 10
    @State private var fanDrafts: [String: Double] = [:]

    private var client: APIClient { session.client }

    var body: some View {
        DetailCard(title: "Controls", systemImage: "slider.horizontal.3") {
            if let status, session.can("printers:control"), status.connected {
                Toggle(isOn: Binding(get: { status.chamberLight ?? false }, set: { on in
                    Task { await runner.run { try await client.call(.post, "printers/\(printerId)/chamber-light", query: ["on": .bool(on)]) } }
                })) { Label("Chamber Light", systemImage: "lightbulb") }

                fanSlider("Part Fan", key: "part", value: status.coolingFanSpeed)
                fanSlider("Aux Fan", key: "aux", value: status.bigFan1Speed)
                fanSlider("Chamber Fan", key: "chamber", value: status.bigFan2Speed)

                if status.airductMode != nil, status.supportsChamberHeater == true || status.exhaustFanPresent == true {
                    Picker("Airduct", selection: Binding(get: { status.airductMode ?? 0 }, set: { mode in
                        Task { await runner.run { try await client.call(.post, "printers/\(printerId)/airduct-mode", query: ["mode": .string(mode == 1 ? "heating" : "cooling")]) } }
                    })) {
                        Text("Cooling").tag(0)
                        Text("Heating").tag(1)
                    }
                    .pickerStyle(.segmented)
                }

                if status.isDualNozzle {
                    Picker("Active Extruder", selection: Binding(get: { status.activeExtruder ?? 0 }, set: { ext in
                        Task { await runner.run { try await client.call(.post, "printers/\(printerId)/select-extruder", query: ["extruder": .int(ext)]) } }
                    })) {
                        Text("Right").tag(0)
                        Text("Left").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .disabled(status.isActiveJob)
                }

                if !status.isActiveJob {
                    Divider()
                    MovementPad(printerId: printerId, runner: runner, step: $jogStep)
                }

                if let options = status.printOptions {
                    Divider()
                    PrintOptionsSection(printerId: printerId, options: options, runner: runner)
                }
            } else if status?.connected == false {
                Text("Printer is offline.").foregroundStyle(.secondary)
            } else {
                Text("You don't have permission to control this printer.").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func fanSlider(_ title: String, key: String, value: Int?) -> some View {
        if let value {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Label(title, systemImage: "fan")
                    Spacer()
                    Text("\(Int(fanDrafts[key] ?? Double(value)))%").monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { fanDrafts[key] ?? Double(value) }, set: { fanDrafts[key] = $0 }), in: 0...100, step: 10) { editing in
                    guard !editing, let v = fanDrafts[key] else { return }
                    Task {
                        await runner.run { try await client.call(.post, "printers/\(printerId)/fan-speed", query: ["fan": .string(key), "speed": .int(Int(v))]) }
                        try? await Task.sleep(for: .seconds(3))
                        fanDrafts[key] = nil
                    }
                }
            }
        }
    }
}

struct MovementPad: View {
    @Environment(AppSession.self) private var session
    let printerId: Int
    let runner: ActionRunner
    @Binding var step: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Movement", systemImage: "move.3d").font(.subheadline.weight(.semibold))
                Spacer()
                Picker("Step", selection: $step) {
                    Text("1 mm").tag(1.0)
                    Text("10 mm").tag(10.0)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
            }
            HStack(alignment: .center, spacing: 24) {
                Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                    GridRow { Color.clear.frame(width: 44, height: 44); jog("arrow.up", x: 0, y: step); Color.clear.frame(width: 44, height: 44) }
                    GridRow { jog("arrow.left", x: -step, y: 0); home("xy"); jog("arrow.right", x: step, y: 0) }
                    GridRow { Color.clear.frame(width: 44, height: 44); jog("arrow.down", x: 0, y: -step); Color.clear.frame(width: 44, height: 44) }
                }
                VStack(spacing: 6) {
                    Text("Bed").font(.caption).foregroundStyle(.secondary)
                    padButton("arrow.up.to.line") { try await call("bed-jog", ["distance": .double(-step)]) }
                    home("z")
                    padButton("arrow.down.to.line") { try await call("bed-jog", ["distance": .double(step)]) }
                }
                VStack(spacing: 6) {
                    Text("Extruder").font(.caption).foregroundStyle(.secondary)
                    padButton("chevron.up") { try await call("extruder-jog", ["distance": .double(-step)]) }
                    Color.clear.frame(width: 44, height: 44)
                    padButton("chevron.down") { try await call("extruder-jog", ["distance": .double(step)]) }
                }
            }
            .frame(maxWidth: .infinity)
            Button { Task { await runner.run("Homing all axes") { try await call("home-axes", ["axes": "all"]) } } } label: {
                Label("Home All", systemImage: "house").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private func call(_ path: String, _ query: [String: QueryValue?]) async throws {
        try await session.client.call(.post, "printers/\(printerId)/\(path)", query: query)
    }

    private func jog(_ icon: String, x: Double, y: Double) -> some View {
        padButton(icon) { try await call("xy-jog", ["x": .double(x), "y": .double(y)]) }
    }

    private func home(_ axes: String) -> some View {
        padButton("house.fill") { try await call("home-axes", ["axes": .string(axes)]) }
    }

    private func padButton(_ icon: String, action: @escaping () async throws -> Void) -> some View {
        Button { Task { await runner.run { try await action() } } } label: {
            Image(systemName: icon).frame(width: 44, height: 44)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 10))
    }
}

struct PrintOptionsSection: View {
    @Environment(AppSession.self) private var session
    let printerId: Int
    let options: PrintOptions
    let runner: ActionRunner

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("AI Detection & Options", systemImage: "eye").font(.subheadline.weight(.semibold))
            option("Spaghetti Detection", "spaghetti_detector", options.spaghettiDetector, sensitivity: options.haltPrintSensitivity)
            option("First Layer Inspection", "first_layer_inspector", options.firstLayerInspector)
            option("Print Quality Monitor", "printing_monitor", options.printingMonitor)
            option("Build Plate Marker Detection", "buildplate_marker_detector", options.buildplateMarkerDetector)
            option("Allow Skipping Parts", "allow_skip_parts", options.allowSkipParts)
            option("Nozzle Clumping Detection", "clump_detector", options.nozzleClumpingDetector, sensitivity: options.nozzleClumpingSensitivity)
            option("Pile-up Detection", "pileup_detector", options.pileupDetector, sensitivity: options.pileupSensitivity)
            option("Air Printing Detection", "airprint_detector", options.airprintDetector, sensitivity: options.airprintSensitivity)
            option("Auto-Recover Step Loss", "auto_recovery_step_loss", options.autoRecoveryStepLoss)
        }
    }

    @ViewBuilder
    private func option(_ title: String, _ module: String, _ value: Bool?, sensitivity: String? = nil) -> some View {
        if let value {
            HStack {
                Toggle(title, isOn: Binding(get: { value }, set: { on in set(module, on, sensitivity ?? "medium") }))
            }
            if value, let sensitivity {
                Picker("Sensitivity", selection: Binding(get: { sensitivity }, set: { set(module, true, $0) })) {
                    Text("Low").tag("low")
                    Text("Medium").tag("medium")
                    Text("High").tag("high")
                }
                .pickerStyle(.segmented)
                .font(.caption)
            }
        }
    }

    private func set(_ module: String, _ enabled: Bool, _ sensitivity: String) {
        Task {
            await runner.run {
                try await session.client.call(.post, "printers/\(printerId)/print-options", query: [
                    "module_name": .string(module), "enabled": .bool(enabled), "print_halt": true, "sensitivity": .string(sensitivity),
                ])
            }
        }
    }
}
