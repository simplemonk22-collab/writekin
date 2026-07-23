import SwiftUI
import Charts

struct StatusBadge: View {
    let status: String
    private var loc: Localization { .shared }
    var body: some View {
        Text(label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
    /// Localized display for the raw stored status token; unknown tokens
    /// fall back to the token itself.
    private var label: String {
        switch status {
        case "succeeded": loc.t(.trStatusSucceeded)
        case "running": loc.t(.trStatusRunning)
        case "failed": loc.t(.trStatusFailed)
        case "cancelled": loc.t(.trStatusCancelled)
        default: status
        }
    }
    private var color: Color {
        switch status {
        case "succeeded": .green
        case "running": .blue
        case "failed": .red
        default: .secondary
        }
    }
}


/// Applies scroll+zoom to the loss chart only when zoomed: the x-axis
/// shows a `visibleSpan` window (scrollable), and the y-axis re-fits to
/// the points inside that window — without this, zooming into the tail
/// still scales y to the whole run's early cliff and the val bottom stays
/// a flat line.
struct LossChartZoom: ViewModifier {
    let zoom: Double
    let visibleSpan: Int
    @Binding var scrollX: Double
    let points: [TrainModel.LossPoint]

    func body(content: Content) -> some View {
        if zoom <= 1.05 {
            content
        } else {
            let window = Int(scrollX)...(Int(scrollX) + visibleSpan)
            let visible = points.filter { window.contains($0.iteration) }
            let lows = visible.map(\.loss)
            let (lo, hi) = (lows.min() ?? 0, lows.max() ?? 1)
            let pad = max(0.02, (hi - lo) * 0.1)
            content
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: visibleSpan)
                .chartScrollPosition(x: $scrollX)
                .chartYScale(domain: (lo - pad)...(hi + pad))
        }
    }
}


/// Compact "Insights" chip that opens the run's plain-language diagnosis
/// (`RunAdvice`) in a popover — the advice is there when wanted without
/// stacking caption lines onto every card.
struct RunInsightsButton: View {
    let lines: [String]
    @State private var showDetails = false
    private var loc: Localization { .shared }

    var body: some View {
        Button {
            showDetails.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "lightbulb")
                    .font(.caption)
                Text(loc.t(.trInsights))
                    .font(.caption.weight(.medium))
                Text("\(lines.count)")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.yellow.opacity(0.2), in: Capsule())
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.yellow.opacity(0.1), in: Capsule())
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(loc.t(.trInsightsHelp))
        .popover(isPresented: $showDetails, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(lines, id: \.self) { line in
                    Label(line, systemImage: "lightbulb")
                        .font(.caption)
                        .foregroundStyle(.primary)
                        // Full text, wrapped — popovers are safe territory
                        // for fixedSize (no AppKit List adjacency).
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                Text(loc.t(.trInsightsFooter))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(width: 380, alignment: .leading)
        }
    }
}
