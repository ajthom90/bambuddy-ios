import SwiftUI
import UIKit

// MARK: Models

struct PrintableObjectsResponse: Codable, Sendable, Hashable {
    var objects: [PrintableObject]
    var total: Int?
    var skippedCount: Int?
    var isPrinting: Bool?
    var bboxAll: [Double]?
}

struct PrintableObject: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var name: String?
    var x: Double?
    var y: Double?
    var skipped: Bool?

    var displayName: String { (name?.isEmpty ?? true) ? "Object \(id)" : name! }
    var isSkipped: Bool { skipped ?? false }
}

struct SkipObjectsResult: Codable, Sendable, Hashable {
    var success: Bool?
    var message: String?
    var skippedObjects: [Int]?
}

/// The slicer's object-ID mask (`cover?view=pick`): every object's pixels are
/// painted with a color whose RGB bytes encode its identify id (R is the low byte).
struct PrintObjectPickMask: Sendable {
    let width: Int
    let height: Int
    /// Decoded object id per pixel (0 = background).
    let ids: [Int]

    init(width: Int, height: Int, ids: [Int]) {
        self.width = width
        self.height = height
        self.ids = ids
    }

    /// Decodes a PNG without any color management so pixel values stay exact.
    init?(pngData: Data) {
        guard let provider = CGDataProvider(data: pngData as CFData),
              let image = CGImage(pngDataProviderSource: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
                ?? UIImage(data: pngData)?.cgImage
        else { return nil }
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var ids = [Int](repeating: 0, count: w * h)
        if image.bitsPerComponent == 8, image.bitsPerPixel == 32 || image.bitsPerPixel == 24,
           let data = image.dataProvider?.data, let base = CFDataGetBytePtr(data) {
            let bpp = image.bitsPerPixel / 8
            let row = image.bytesPerRow
            let alpha = image.alphaInfo
            let byteOrder = image.bitmapInfo.intersection(.byteOrderMask)
            let little = byteOrder == .byteOrder32Little
            let alphaFirst = alpha == .first || alpha == .premultipliedFirst || alpha == .noneSkipFirst
            let hasAlpha = alpha != .none && alpha != .noneSkipFirst && alpha != .noneSkipLast
            for y in 0..<h {
                for x in 0..<w {
                    let p = base + y * row + x * bpp
                    var r: Int, g: Int, b: Int, a: Int = 255
                    if bpp == 3 {
                        r = Int(p[0]); g = Int(p[1]); b = Int(p[2])
                    } else if little {
                        // BGRA / ABGR in memory.
                        if alphaFirst { b = Int(p[0]); g = Int(p[1]); r = Int(p[2]); a = Int(p[3]) }
                        else { a = Int(p[0]); b = Int(p[1]); g = Int(p[2]); r = Int(p[3]) }
                    } else if alphaFirst {
                        a = Int(p[0]); r = Int(p[1]); g = Int(p[2]); b = Int(p[3])
                    } else {
                        r = Int(p[0]); g = Int(p[1]); b = Int(p[2]); a = Int(p[3])
                    }
                    if !hasAlpha { a = 255 }
                    ids[y * w + x] = Self.decode(r: r, g: g, b: b, a: a)
                }
            }
        } else {
            // Unusual pixel format: redraw into RGBA8 using the image's own color space.
            guard let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let raw = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
            for i in 0..<(w * h) {
                let p = raw + i * 4
                ids[i] = Self.decode(r: Int(p[0]), g: Int(p[1]), b: Int(p[2]), a: Int(p[3]))
            }
        }
        self.init(width: w, height: h, ids: ids)
    }

    static func decode(r: Int, g: Int, b: Int, a: Int) -> Int {
        guard a > 0 else { return 0 }
        return r + (g << 8) + (b << 16)
    }

    func id(atX x: Int, y: Int) -> Int? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let v = ids[y * width + x]
        return v == 0 ? nil : v
    }

    /// Maps a point in a `box`-sized view showing the mask aspect-fit to a mask pixel.
    func pixel(for point: CGPoint, in box: CGSize) -> (x: Int, y: Int)? {
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = min(box.width / CGFloat(width), box.height / CGFloat(height))
        let ox = (box.width - CGFloat(width) * scale) / 2
        let oy = (box.height - CGFloat(height) * scale) / 2
        let mx = (point.x - ox) / scale, my = (point.y - oy) / scale
        guard mx >= 0, my >= 0, mx < CGFloat(width), my < CGFloat(height) else { return nil }
        return (min(width - 1, Int(mx)), min(height - 1, Int(my)))
    }

    /// Renders a translucent overlay highlighting selected and skipped objects.
    func overlay(selected: Set<Int>, skipped: Set<Int>) -> UIImage? {
        guard !selected.isEmpty || !skipped.isEmpty else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let id = ids[y * width + x]
                guard id != 0 else { continue }
                var rgba: (UInt8, UInt8, UInt8, UInt8)?
                if skipped.contains(id) {
                    rgba = (148, 163, 184, 175)
                } else if selected.contains(id) {
                    rgba = ((x + y) / 7) % 2 == 0 ? (37, 199, 91, 205) : (74, 222, 128, 145)
                }
                guard let c = rgba else { continue }
                let i = (y * width + x) * 4
                // Premultiplied for CGImage.
                let a = Double(c.3) / 255
                pixels[i] = UInt8(Double(c.0) * a); pixels[i + 1] = UInt8(Double(c.1) * a)
                pixels[i + 2] = UInt8(Double(c.2) * a); pixels[i + 3] = c.3
            }
        }
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: View

struct SkipObjectsView: View {
    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let printerId: Int

    @State private var loader = Loader<PrintableObjectsResponse>()
    @State private var runner = ActionRunner()
    @State private var selected: Set<Int> = []
    @State private var mask: PrintObjectPickMask?
    @State private var maskUnavailable = false
    @State private var overlay: UIImage?
    @State private var confirmSkip = false
    @State private var fullscreenPlate = false

    private var status: PrinterStatus? { store.statuses[printerId] }
    private var client: APIClient { session.client }
    private var layer: Int { status?.layerNum ?? 0 }
    private var tooEarly: Bool { layer <= 1 }
    private var canControl: Bool { session.can("printers:control") }

    var body: some View {
        LoadingContent(loader: loader, retry: { await load(reload: true) }) { response in
            let objects = response.objects
            if objects.isEmpty {
                ContentUnavailableView {
                    Label("No Objects Found", systemImage: "square.dashed")
                } description: {
                    Text("Objects are read from the print file when a print starts.")
                } actions: {
                    Button("Reload from Printer") { Task { await load(reload: true) } }.buttonStyle(.bordered)
                }
            } else {
                content(objects: objects, response: response)
            }
        }
        .navigationTitle("Skip Objects")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { Task { await load(reload: true) } } label: { Label("Reload from Printer", systemImage: "arrow.clockwise") }
                    if let objects = loader.value?.objects {
                        let active = objects.filter { !$0.isSkipped }.map(\.id)
                        Button { selected = Set(active) } label: { Label("Select All", systemImage: "checkmark.circle") }
                            .disabled(active.isEmpty)
                        Button { selected = [] } label: { Label("Deselect All", systemImage: "circle") }
                            .disabled(selected.isEmpty)
                    }
                } label: { Image(systemName: "ellipsis") }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let objects = loader.value?.objects, !objects.isEmpty, canControl {
                Button(role: .destructive) { confirmSkip = true } label: {
                    Label(selected.isEmpty ? "Select Objects to Skip" : "Skip \(selected.count) Object\(selected.count == 1 ? "" : "s")", systemImage: "forward.end")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
                .disabled(selected.isEmpty || tooEarly || runner.isRunning)
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
        }
        .task { await load(reload: false) }
        .task { await loadMask() }
        .task {
            // Keep skipped states current while the view is open.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if !Task.isCancelled { await load(reload: false) }
            }
        }
        .onChange(of: selected) { rebuildOverlay() }
        .onChange(of: loader.value?.objects.filter(\.isSkipped).map(\.id)) { rebuildOverlay() }
        .actionAlerts(runner)
        .confirmationDialog(confirmTitle, isPresented: $confirmSkip, titleVisibility: .visible) {
            Button(allRemainingSelected ? "Skip and Stop Print" : "Skip", role: .destructive) { Task { await skip() } }
        } message: {
            Text(confirmMessage)
        }
        .fullScreenCover(isPresented: $fullscreenPlate) {
            NavigationStack {
                plate(objects: loader.value?.objects ?? [])
                    .padding()
                    .navigationTitle("Plate")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { fullscreenPlate = false } } }
            }
        }
    }

    @ViewBuilder
    private func content(objects: [PrintableObject], response: PrintableObjectsResponse) -> some View {
        let skippedCount = objects.filter(\.isSkipped).count
        List {
            if tooEarly && status?.isActiveJob == true {
                Section {
                    Label("Objects can be skipped from layer 2 onward (currently layer \(layer)).", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } else if response.isPrinting == false {
                Section {
                    Label("No print is running.", systemImage: "info.circle").foregroundStyle(.secondary)
                }
            }
            Section {
                plate(objects: objects)
                    .frame(maxWidth: 480, maxHeight: 480)
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    .overlay(alignment: .topTrailing) {
                        Button { fullscreenPlate = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").padding(6) }
                            .buttonStyle(.glass)
                            .padding(12)
                    }
            } footer: {
                HStack {
                    Text("\(selected.count) of \(objects.count - skippedCount) selected")
                    Spacer()
                    if skippedCount > 0 { Text("\(skippedCount) skipped") }
                    if maskUnavailable { Text("Plate preview unavailable") }
                }
            }
            Section("Objects") {
                ForEach(Array(objects.enumerated()), id: \.element.id) { index, object in
                    Button { toggle(object) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: object.isSkipped || selected.contains(object.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(object.isSkipped ? Color.red : selected.contains(object.id) ? Color.green : Color.secondary)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(index + 1). \(object.displayName)")
                                    .strikethrough(object.isSkipped)
                                    .foregroundStyle(object.isSkipped ? .red : .primary)
                                Text("ID \(object.id)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if object.isSkipped { StatusBadge(text: "Skipped", color: .red) }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(object.isSkipped || !canControl)
                }
            }
        }
        .refreshable { await load(reload: false) }
    }

    @ViewBuilder
    private func plate(objects: [PrintableObject]) -> some View {
        GeometryReader { geo in
            let box = geo.size
            ZStack {
                RemoteImage(path: "printers/\(printerId)/cover", contentMode: .fit, reloadKey: status?.gcodeFile, systemImage: "cube")
                    .frame(width: box.width, height: box.height)
                if let overlay {
                    Image(uiImage: overlay)
                        .interpolation(.none)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: box.width, height: box.height)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(.rect)
            .gesture(SpatialTapGesture().onEnded { value in
                guard let mask, let px = mask.pixel(for: value.location, in: box),
                      let id = mask.id(atX: px.x, y: px.y),
                      let object = objects.first(where: { $0.id == id }) else { return }
                toggle(object)
            })
        }
        .aspectRatio(1, contentMode: .fit)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
        .clipShape(.rect(cornerRadius: 12))
    }

    private var allRemainingSelected: Bool {
        guard let objects = loader.value?.objects else { return false }
        let active = Set(objects.filter { !$0.isSkipped }.map(\.id))
        return !active.isEmpty && active.isSubset(of: selected)
    }

    private var confirmTitle: String { selected.count == 1 ? "Skip Object?" : "Skip \(selected.count) Objects?" }

    private var confirmMessage: String {
        if allRemainingSelected { return "All remaining objects are selected, which will end the print. This cannot be undone." }
        if selected.count == 1, let id = selected.first, let o = loader.value?.objects.first(where: { $0.id == id }) {
            return "“\(o.displayName)” will not be printed further. This cannot be undone."
        }
        return "The selected objects will not be printed further. This cannot be undone."
    }

    private func toggle(_ object: PrintableObject) {
        guard !object.isSkipped, canControl else { return }
        if selected.contains(object.id) { selected.remove(object.id) } else { selected.insert(object.id) }
    }

    private func load(reload: Bool) async {
        await loader.load { try await client.get("printers/\(printerId)/print/objects", query: ["reload": reload ? true : nil]) }
        if let objects = loader.value?.objects {
            let skipped = Set(objects.filter(\.isSkipped).map(\.id))
            selected.subtract(skipped)
        }
    }

    private func loadMask() async {
        let url = await session.mediaURL("printers/\(printerId)/cover", query: ["view": "pick"])
        do {
            var req = client.makeRequest(.get, url.absoluteString)
            req.setValue("image/png,*/*", forHTTPHeaderField: "Accept")
            let data = try await client.rawData(req)
            let decoded = await Task.detached(priority: .userInitiated) { PrintObjectPickMask(pngData: data) }.value
            mask = decoded
            maskUnavailable = decoded == nil
            rebuildOverlay()
        } catch {
            maskUnavailable = true
        }
    }

    private func rebuildOverlay() {
        guard let mask else { overlay = nil; return }
        let skipped = Set((loader.value?.objects ?? []).filter(\.isSkipped).map(\.id))
        overlay = mask.overlay(selected: selected, skipped: skipped)
    }

    private func skip() async {
        let ids = Array(selected).sorted()
        await runner.run {
            let result: SkipObjectsResult = try await client.send(.post, "printers/\(printerId)/print/skip-objects", body: ids)
            runner.successMessage = result.message ?? "Objects skipped"
            selected = []
            await load(reload: false)
        }
    }
}
