import SwiftUI

/// Grid of live camera feeds for every printer.
struct CamWallView: View {
    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var store
    @State private var fullscreen: Printer?
    @AppStorage("camWallColumns") private var columnsPreference = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                let columns = columnsPreference == 0
                    ? [GridItem(.adaptive(minimum: 300), spacing: 12)]
                    : Array(repeating: GridItem(.flexible(), spacing: 12), count: columnsPreference)
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(store.printers.filter(\.isActive)) { printer in
                        let status = store.statuses[printer.id]
                        ZStack(alignment: .bottomLeading) {
                            PrinterCameraView(printerId: printer.id, rotation: printer.cameraRotation ?? 0, fps: 5)
                                .aspectRatio(16 / 9, contentMode: .fit)
                            HStack {
                                Text(printer.name).font(.caption.weight(.semibold))
                                if let status, status.isActiveJob {
                                    Text("\(Fmt.percent(status.progress)) · \(Fmt.minutes(status.remainingTime))").font(.caption2).monospacedDigit()
                                }
                                Spacer()
                                PrinterStateBadge(status: status)
                            }
                            .padding(8)
                            .background(.ultraThinMaterial)
                        }
                        .clipShape(.rect(cornerRadius: 12))
                        .onTapGesture { fullscreen = printer }
                    }
                }
                .padding()
            }
            .overlay {
                if store.printers.isEmpty { ContentUnavailableView("No Printers", systemImage: "video.slash") }
                else if !session.can("camera:view") { ContentUnavailableView("No Camera Access", systemImage: "lock") }
            }
            .navigationTitle("Camera Wall")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Picker("Columns", selection: $columnsPreference) {
                        Text("Auto").tag(0)
                        ForEach(1...4, id: \.self) { Text("\($0) Columns").tag($0) }
                    }
                }
            }
            .fullScreenCover(item: $fullscreen) { printer in
                FullscreenCameraView(printerId: printer.id, title: printer.name, rotation: printer.cameraRotation ?? 0)
            }
        }
    }
}
