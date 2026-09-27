import SwiftUI
import Charts

/// Dashboard card with a titled header.
struct StatsCard<Content: View, Accessory: View>: View {
    let title: String
    let systemImage: String
    var tint: Color = .accentColor
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(_ title: String, systemImage: String, tint: Color = .accentColor,
         @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() },
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                    .labelStyle(StatsTintedLabelStyle(tint: tint))
                Spacer(minLength: 8)
                accessory()
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
    }
}

/// Inner panel used inside wide cards.
struct StatsPanel<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                accessory()
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(.tertiarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }
}

private struct StatsTintedLabelStyle: LabelStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}

/// Compact segmented picker for weight / prints / time metrics.
struct StatsMetricPicker: View {
    @Binding var metric: StatsMetricKind
    var options: [StatsMetricKind] = StatsMetricKind.allCases
    var body: some View {
        Picker("Metric", selection: $metric) {
            ForEach(options) { m in Text(m.title).tag(m) }
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .fixedSize()
    }
}

/// Circular progress ring with centered content.
struct StatsRing<Center: View>: View {
    let fraction: Double
    var color: Color = .green
    var lineWidth: CGFloat = 11
    var size: CGFloat = 116
    @ViewBuilder var center: () -> Center

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0, min(1, fraction)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.snappy, value: fraction)
            center()
        }
        .frame(width: size, height: size)
    }
}

/// A single labelled metric tile.
struct StatsValueTile: View {
    let label: String
    let value: String
    let systemImage: String
    var tint: Color = .accentColor
    var warning: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.14), in: .rect(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                    if warning != nil {
                        Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.yellow)
                    }
                }
                Text(value)
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(warning ?? "")
    }
}

/// Placeholder shown inside a card when there is nothing to chart.
struct StatsEmptyNote: View {
    let text: String
    var height: CGFloat = 120
    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: height)
    }
}

/// Donut chart with a legend listing value and share.
struct StatsDonut: View {
    let data: [StatsNamedValue]
    let color: (Int, StatsNamedValue) -> Color
    let format: (Double) -> String
    var legendName: (StatsNamedValue) -> String = { $0.name }
    var legendLimit = 8
    var centerTitle: String?
    var centerSubtitle: String?
    @State private var selected: Double?

    private var total: Double { data.reduce(0) { $0 + $1.value } }

    private var selectedEntry: StatsNamedValue? {
        guard let selected else { return nil }
        var acc = 0.0
        for d in data { acc += d.value; if selected <= acc { return d } }
        return nil
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) { chart; legend }
            VStack(spacing: 12) { chart; legend }
        }
    }

    private var chart: some View {
        Chart(Array(data.enumerated()), id: \.element.id) { index, entry in
            SectorMark(angle: .value("Value", entry.value), innerRadius: .ratio(0.58), angularInset: 1.5)
                .cornerRadius(3)
                .foregroundStyle(color(index, entry))
                .opacity(selectedEntry == nil || selectedEntry == entry ? 1 : 0.4)
        }
        .chartAngleSelection(value: $selected)
        .chartBackground { _ in
            VStack(spacing: 0) {
                if let s = selectedEntry {
                    Text(format(s.value)).font(.subheadline.weight(.bold)).monospacedDigit()
                    Text(legendName(s)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    if let centerTitle { Text(centerTitle).font(.subheadline.weight(.bold)).monospacedDigit() }
                    if let centerSubtitle { Text(centerSubtitle).font(.caption2).foregroundStyle(.secondary) }
                }
            }
            .padding(.horizontal, 24)
            .minimumScaleFactor(0.6)
        }
        .frame(width: 150, height: 150)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(data.prefix(legendLimit).enumerated()), id: \.element.id) { index, entry in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color(index, entry))
                        .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(.primary.opacity(0.2)) }
                        .frame(width: 11, height: 11)
                    Text(legendName(entry)).font(.subheadline).lineLimit(1)
                    Spacer(minLength: 6)
                    Text("\(format(entry.value)) · \(total > 0 ? Int((entry.value / total * 100).rounded()) : 0)%")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if data.count > legendLimit {
                Text("+\(data.count - legendLimit) more").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 320)
    }
}

enum StatsPalette {
    static let series: [Color] = [.green, .blue, .orange, .red, .purple, .pink, .teal, .indigo, .mint, .brown]
    static func color(_ index: Int) -> Color { series[index % series.count] }
    static func rate(_ rate: Double) -> Color { rate >= 90 ? .green : rate >= 70 ? .orange : .red }
    static func heat(_ count: Int, max: Int) -> Color {
        guard count > 0 else { return Color.secondary.opacity(0.14) }
        let intensity = Double(count) / Double(Swift.max(max, 1))
        let steps: Double = intensity <= 0.25 ? 0.3 : intensity <= 0.5 ? 0.5 : intensity <= 0.75 ? 0.75 : 1
        return Color.green.opacity(steps)
    }
}

/// "Less ▢▢▢▢▢ More" legend for heatmaps.
struct StatsHeatLegend: View {
    var body: some View {
        HStack(spacing: 4) {
            Text("Less").font(.caption2).foregroundStyle(.secondary)
            ForEach([0, 1, 2, 3, 4], id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(StatsPalette.heat(i, max: 4))
                    .frame(width: 11, height: 11)
            }
            Text("More").font(.caption2).foregroundStyle(.secondary)
        }
    }
}
