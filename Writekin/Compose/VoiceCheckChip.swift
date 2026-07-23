import SwiftUI

/// Compact voice-check scoreboard: "Signals: 5/7" with a verdict dot,
/// expanding on click to the full per-signal breakdown. One instance per
/// checked text (fine-tuned and base), each owning its popover state, so
/// the two chips read as a side-by-side score.
struct VoiceCheckChip: View {
    let check: VoiceCheck
    /// Which text this chip scores ("Draft"/"Realized"/"Base") — nil for
    /// the plain single-chip case.
    var title: String? = nil
    @State private var showDetails = false
    private var loc: Localization { .shared }

    private var dotColor: Color {
        if check.countableTotal == 0 { return .secondary.opacity(0.5) }
        return check.hasOff ? .orange : .green
    }

    var body: some View {
        Button {
            showDetails.toggle()
        } label: {
            HStack(spacing: 6) {
                Circle().fill(dotColor).frame(width: 7, height: 7)
                Text("\(title ?? loc.t(.cpChipSignals)): \(check.matchCount)/\(check.countableTotal)")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(dotColor.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(loc.t(.cpChipHelp))
        .popover(isPresented: $showDetails, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(check.signals) { signal in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle()
                            .fill(signal.verdict == .match ? Color.green
                                  : signal.verdict == .off ? Color.orange
                                  : Color.secondary.opacity(0.5))
                            .frame(width: 6, height: 6)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(signal.label)
                                .font(.caption.weight(.semibold))
                            Text(signal.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Divider()
                Text(loc.t(.cpChipFooter))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(width: 360, alignment: .leading)
        }
    }
}
