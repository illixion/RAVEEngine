/*
 RAVE Engine — the presentation half: a scrolling frame-time graph and a stat row.

 Both are lifted from Longwave's PCVR panel, the richest of the four HUDs and
 the only one whose design decisions had already been paid for on device. The
 comments explaining *why* each choice is the way it is come with them, because
 those are the parts that get "simplified" back into the bug they fixed.

 These are `@MainActor` — SwiftUI always is. The collection side deliberately
 is not, so a render thread can feed what these draw.
 */

#if canImport(SwiftUI)

import SwiftUI

/// Threshold-tinted number over a caption. The unit of every one of these HUDs.
public struct RAVEStatView: View {
    public let label: String
    public let value: String
    public let tint: Color?

    public init(_ label: String, value: String, tint: Color? = nil) {
        self.label = label
        self.value = value
        self.tint = tint
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint ?? .primary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

public extension RAVEStatView {
    /// A numeric stat, or an em dash when the feed gate says the number can no
    /// longer be vouched for. Passing the optional through here rather than
    /// branching at the call site is what makes "no data" the easy path.
    init(_ label: String, value: Double?, format: String = "%.1f", tint: Color? = nil) {
        self.init(label, value: value.map { String(format: format, $0) } ?? "—", tint: tint)
    }
}

/// Scrolling frame-period graph.
///
/// Bars rather than a line: a single 40 ms spike in a line chart reads as a
/// slope between two good frames, and the spike is the whole point.
public struct RAVEFrameTimeGraph: View {
    /// Frame periods in milliseconds, oldest first.
    public let periodsMs: [Double]
    /// How many bar slots the width is divided into. Fixing this rather than
    /// deriving it from the sample count is what keeps bars a constant width
    /// while the buffer fills.
    public let slots: Int
    /// Placeholder drawn when there is nothing to plot — a dead feed must look
    /// dead, not like a flat line at zero.
    public let emptyLabel: String

    public init(periodsMs: [Double], slots: Int = 180, emptyLabel: String = "No data") {
        self.periodsMs = periodsMs
        self.slots = Swift.max(1, slots)
        self.emptyLabel = emptyLabel
    }

    /// Guides at the rates a host might be pacing to. Whichever fit the current
    /// ceiling are drawn, so the graph annotates itself instead of needing a
    /// legend.
    private static let guides: [(ms: Double, label: String)] = [
        (8.33, "120"), (11.11, "90"), (16.67, "60")
    ]

    public var body: some View {
        Canvas { context, size in
            guard !periodsMs.isEmpty else { return }
            // Scaled to the 95th percentile, not the maximum: a single 65 ms
            // hitch set the ceiling so high that every guide line collapsed
            // onto the baseline and the graph became one spike over an empty
            // box. Outliers clip to the top instead, where they are still
            // perfectly visible as a full-height bar.
            let sorted = periodsMs.sorted()
            let p95 = sorted[Swift.min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            let ceiling = Swift.max(20, p95 * 1.3)
            let y = { (ms: Double) in size.height * CGFloat(1 - Swift.min(ms, ceiling) / ceiling) }

            for guide in Self.guides where guide.ms < ceiling {
                let line = Path { path in
                    path.move(to: CGPoint(x: 0, y: y(guide.ms)))
                    path.addLine(to: CGPoint(x: size.width, y: y(guide.ms)))
                }
                context.stroke(line, with: .color(.white.opacity(0.18)),
                               style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                context.draw(
                    Text(guide.label).font(.system(size: 8)).foregroundStyle(.tertiary),
                    at: CGPoint(x: size.width - 8, y: y(guide.ms) - 5), anchor: .trailing
                )
            }

            // Right-aligned: the newest frame is always at the same edge, so
            // the eye can track "now" without re-finding it as the buffer fills.
            let barWidth = size.width / CGFloat(slots)
            let offset = slots - periodsMs.count
            for (index, ms) in periodsMs.enumerated() {
                let top = y(ms)
                let rect = CGRect(x: CGFloat(index + offset) * barWidth, y: top,
                                  width: Swift.max(barWidth - 0.5, 0.5), height: size.height - top)
                // Coloured by severity, not by index: 90 Hz is fine, 60 is a
                // compromise, below that is a stutter the user felt.
                let color: Color = ms <= 12 ? .green : ms <= 17 ? .yellow : .orange
                context.fill(Path(rect), with: .color(color.opacity(0.85)))
            }
        }
        .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .center) {
            if periodsMs.isEmpty {
                Text(emptyLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A compact table of every metric in a snapshot, worst-spiking first.
///
/// The generic readout, for a HUD that has not yet earned a bespoke layout —
/// which is what three of the four apps were printing to the console instead.
public struct RAVEMetricTable: View {
    public let snapshot: RAVEMetricSnapshot
    public let limit: Int
    /// Milliseconds past which a value is tinted as a problem. Nil disables
    /// tinting, for metrics that are not durations.
    public let warnThresholdMs: Double?

    public init(snapshot: RAVEMetricSnapshot, limit: Int = 8, warnThresholdMs: Double? = 16.67) {
        self.snapshot = snapshot
        self.limit = limit
        self.warnThresholdMs = warnThresholdMs
    }

    public var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
            GridRow {
                Text("").gridColumnAlignment(.leading)
                ForEach(["mean", "p95", "max"], id: \.self) { heading in
                    Text(heading).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            ForEach(snapshot.worstFirst(limit: limit), id: \.key) { entry in
                GridRow {
                    Text(entry.key).font(.caption).foregroundStyle(.secondary)
                    cell(entry.stat.mean)
                    cell(entry.stat.p95)
                    cell(entry.stat.max)
                }
            }
        }
    }

    private func cell(_ value: Double) -> some View {
        Text(String(format: "%.2f", value))
            .font(.caption.monospacedDigit())
            .foregroundStyle(tint(for: value))
    }

    private func tint(for value: Double) -> Color {
        guard let warnThresholdMs else { return .primary }
        return value > warnThresholdMs ? .orange : .primary
    }
}

#endif
