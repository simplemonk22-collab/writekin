import SwiftUI
import Charts

/// One medium's chart card: composite score by month, a shaded region from
/// the stored cutoff through the most recent month, a slider (snapped to
/// month positions) to set/move that cutoff, and — when the scan proposed
/// one — an "Accept" shortcut.
struct TimelineCard: View {
    let timeline: MediumTimeline
    let cutoff: String?
    /// The month of a proposal this medium's user explicitly dismissed, if
    /// any — see item 4's doc comment on `ContaminationTimelineView`.
    let dismissedProposal: String?
    let onSetCutoff: (String?) -> Void
    let onDismissProposal: (String) -> Void
    let onProposeAgain: () -> Void
    let onNoCutoffNeeded: () -> Void

    /// The month under the pointer while dragging the cutoff directly on
    /// the chart — drives the line/shading live; committed via
    /// `onSetCutoff` on release, then cleared.
    @State private var dragMonth: String?

    var body: some View {
        GroupBox(mediumTitle) {
            VStack(alignment: .leading, spacing: 10) {
                Text(caption)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                // Anchored directly under this card's own caption (not at
                // the bottom, after the chart/slider) so it unambiguously
                // reads as THIS medium's proposal rather than floating into
                // visual proximity with the next card below.
                if let proposed = timeline.proposedCutoff, proposed != cutoff, dismissedProposal != proposed {
                    HStack(spacing: 8) {
                        Text(Localization.shared.t(.tlProposed, formattedMonth(proposed)))
                            .font(.caption.weight(.medium))
                        Button(Localization.shared.t(.tlAccept)) {
                            onSetCutoff(proposed)
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        Button(Localization.shared.t(.tlDismiss)) {
                            onDismissProposal(proposed)
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                }

                // Only shown while the current scan's proposal is actively
                // being hidden by a dismissal — i.e. the dismissed month
                // still matches what's proposed now. Once a rescan proposes
                // something different, `clearStaleDismissedProposals`
                // clears the marker and this row (along with the proposal
                // row above) goes back to normal.
                if let dismissedProposal, dismissedProposal == timeline.proposedCutoff {
                    HStack(spacing: 6) {
                        Text(Localization.shared.t(.tlProposalDismissed))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Button(Localization.shared.t(.tlProposeAgain)) {
                            onProposeAgain()
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                    }
                }

                if timeline.months.count > 1 {
                    chart
                        .frame(height: 150)
                        // The cutoff is set directly ON the chart: click or
                        // drag anywhere in the plot and the cutoff line +
                        // shaded excluded region follow the pointer; release
                        // commits. Replaces the old below-chart slider,
                        // whose plot-inset alignment dance this also
                        // retires.
                        .chartOverlay { proxy in
                            GeometryReader { geo in
                                Rectangle()
                                    .fill(Color.clear)
                                    .contentShape(Rectangle())
                                    .gesture(
                                        DragGesture(minimumDistance: 0)
                                            .onChanged { value in
                                                dragMonth = month(atOverlayX: value.location.x,
                                                                  proxy: proxy, geo: geo)
                                            }
                                            .onEnded { value in
                                                if let month = month(atOverlayX: value.location.x,
                                                                     proxy: proxy, geo: geo) {
                                                    onSetCutoff(month)
                                                }
                                                dragMonth = nil
                                            })
                            }
                        }

                    Text(Localization.shared.t(.tlChartExplainer, pluralLabel))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Text(Localization.shared.t(
                            .tlCutoffLabel,
                            cutoff.map(formattedMonth) ?? Localization.shared.t(.tlCutoffNone)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if cutoff != nil {
                            Button(Localization.shared.t(.tlClearCutoff)) {
                                onSetCutoff(nil)
                            }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                        }
                        // Explicit "I looked, nothing to exclude" decision —
                        // distinct from just never having visited Timeline
                        // for this medium (see `CutoffStore.markNoCutoffNeeded`
                        // and `PipelineState.timelineReviewed`).
                        Button(Localization.shared.t(.tlNoCutoffNeeded)) {
                            onNoCutoffNeeded()
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// The month band under an overlay-space x position, clamped to the
    /// plot area so drags past either edge resolve to the first/last month
    /// instead of nil.
    private func month(atOverlayX x: CGFloat, proxy: ChartProxy,
                       geo: GeometryProxy) -> String? {
        guard let anchor = proxy.plotFrame else { return nil }
        let rect = geo[anchor]
        let clamped = min(max(x, rect.minX), rect.maxX - 0.5)
        return proxy.value(atX: clamped - rect.minX, as: String.self)
    }

    /// The cutoff to DRAW: the in-flight drag position while the pointer is
    /// down, the stored cutoff otherwise.
    private var displayedCutoff: String? { dragMonth ?? cutoff }

    private var chart: some View {
        Chart {
            if let displayedCutoff,
               let startMonth = timeline.months.first(where: { $0.month >= displayedCutoff })?.month,
               let lastMonth = timeline.months.last?.month {
                RectangleMark(xStart: .value("Start", startMonth), xEnd: .value("End", lastMonth))
                    .foregroundStyle(.orange.opacity(0.15))
                RuleMark(x: .value("Cutoff", startMonth))
                    .foregroundStyle(.orange)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .annotation(position: .top, alignment: .center) {
                        Text(formattedMonth(displayedCutoff))
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.orange.opacity(0.15), in: Capsule())
                            .foregroundStyle(.orange)
                    }
            }
            ForEach(timeline.months.indices, id: \.self) { idx in
                LineMark(x: .value("Month", timeline.months[idx].month),
                         y: .value("AI-tell score", timeline.composite[idx]))
            }
            .foregroundStyle(Color.accentColor)
            .interpolationMethod(.catmullRom)
        }
        .chartXAxis {
            // The x values are categorical "YYYY-MM" strings, and
            // `.automatic(desiredCount:)` does NOT thin a categorical axis —
            // it happily rendered every month of a 20-year span. Hand it the
            // exact tick months instead: Januarys (year boundaries) over
            // long spans, evenly thinned to at most 6 either way.
            AxisMarks(values: xAxisTickMonths) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let month = value.as(String.self) {
                        Text(axisLabel(month))
                    }
                }
            }
        }
        .chartYAxisLabel(Localization.shared.t(.tlYAxisLabel), position: .trailing)
        // Two fixes for chart instability while dragging the cutoff slider:
        // (1) the x axis is categorical "YYYY-MM" strings, and without an
        // explicit domain SwiftUI Charts re-derives/reorders it from
        // whatever marks are present each redraw -- mid-drag, as the
        // RectangleMark's start/end months change every frame, that made
        // the axis (and the line it's plotted against) visibly reflow.
        // Pinning the domain to the full, stable `timeline.months` list
        // fixes it. (2) `.animation(nil, value: cutoff)` suppresses the
        // implicit animation SwiftUI Charts otherwise applies to the
        // RectangleMark's data-driven change on every cutoff update, which
        // was animating the shaded region (and the redraw it triggered)
        // instead of snapping instantly with the slider.
        .chartXScale(domain: timeline.months.map(\.month))
        .animation(nil, value: cutoff)
        .animation(nil, value: dragMonth)
    }

    /// The explicit tick positions for the categorical month axis: January
    /// of each year over long spans (thinned to 6), an even thinning of all
    /// months otherwise. First/last of the chosen set always survive.
    private var xAxisTickMonths: [String] {
        let months = timeline.months.map(\.month)
        if spansManyYears {
            let januarys = months.filter { $0.hasSuffix("-01") }
            if januarys.count >= 3 { return Self.thin(januarys, to: 6) }
        }
        return Self.thin(months, to: 6)
    }

    /// Evenly picks at most `cap` elements, always keeping first and last.
    private static func thin(_ values: [String], to cap: Int) -> [String] {
        guard values.count > cap, cap > 1 else { return values }
        let stride = Double(values.count - 1) / Double(cap - 1)
        return (0..<cap).map { values[Int((Double($0) * stride).rounded())] }
    }

    /// True when the timeline's monthly points span 8+ years — the trigger
    /// for switching to sparser, year-only axis labels.
    private var spansManyYears: Bool {
        guard let first = timeline.months.first?.month, let last = timeline.months.last?.month,
              let firstYear = Int(first.prefix(4)), let lastYear = Int(last.prefix(4))
        else { return false }
        return lastYear - firstYear >= 8
    }

    /// The axis tick label for one "YYYY-MM" month: year-only over a long
    /// span, "MMM yyyy" otherwise. Built from `String(month.prefix(4))`
    /// rather than a numeric formatter so the year is never comma-grouped
    /// (e.g. never "2,010").
    private func axisLabel(_ month: String) -> String {
        spansManyYears ? String(month.prefix(4)) : formattedMonth(month)
    }

    private var mediumTitle: String {
        switch timeline.medium {
        case "email": Localization.shared.t(.brEmail)
        case "sms": Localization.shared.t(.tlMediumTexts)
        case "doc": Localization.shared.t(.brDocs)
        case "chat": Localization.shared.t(.brAIChats)
        default: timeline.medium.capitalized
        }
    }

    private var pluralLabel: String {
        switch timeline.medium {
        case "email": Localization.shared.t(.tlPluralEmails)
        case "sms": Localization.shared.t(.tlPluralTexts)
        case "doc": Localization.shared.t(.tlPluralDocs)
        case "chat": Localization.shared.t(.tlPluralChats)
        default: "\(timeline.medium)s"
        }
    }

    /// Plain-language read of where this medium's writing stands: flags a
    /// weak baseline first (the proposal, if any, isn't trustworthy), then
    /// either names the inflection point or reassures that nothing drifted.
    private var caption: String {
        let loc = Localization.shared
        if timeline.baselineIsWeak {
            return loc.t(.tlCaptionWeakBaseline)
        }
        if let proposed = timeline.proposedCutoff {
            return loc.t(.tlCaptionInflect, pluralLabel, formattedMonth(proposed))
        }
        return loc.t(.tlCaptionClean, pluralLabel)
    }

    private func formattedMonth(_ month: String) -> String {
        let parts = month.split(separator: "-")
        guard parts.count == 2, let y = Int(parts[0]), let m = Int(parts[1]),
              m >= 1, m <= 12 else { return month }
        var components = DateComponents()
        components.year = y
        components.month = m
        components.day = 1
        guard let date = Calendar(identifier: .gregorian).date(from: components) else { return month }
        return date.formatted(.dateTime.month(.abbreviated).year())
    }
}

/// De-black-boxes the "AI tell" score (item 4): an ⓘ button beside the
/// screen's caption opening a popover that explains, in plain language but
/// with exact numbers pulled from `ContaminationScan`, what the y axis
/// actually counts and what it deliberately doesn't do.
struct ScoreExplainerButton: View {
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless)
        .help(Localization.shared.t(.tlScoreExplainerHelp))
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            ScoreExplainerContent()
        }
    }
}

private struct ScoreExplainerContent: View {
    /// The three composite weights, each paired with the localization key of
    /// the plain-language name of the signal it scales — weights pulled
    /// straight from `ContaminationScan` so this list can't silently drift
    /// out of sync with the real scoring.
    private var weightRows: [(labelKey: L10nKey, weight: Double)] {
        [
            (.tlSignalEmDashes, ContaminationScan.emDashWeight),
            (.tlSignalPhrases, ContaminationScan.ticsWeight),
            (.tlSignalLists, ContaminationScan.listRatioWeight),
        ]
    }

    var body: some View {
        let loc = Localization.shared
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(loc.t(.tlExplainerTitle))
                    .font(.headline)

                Text(loc.t(.tlExplainerIntro))
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(weightRows, id: \.labelKey) { row in
                        Text(loc.t(.tlWeightRow, loc.t(row.labelKey), weightString(row.weight)))
                    }
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

                Text(loc.t(.tlExplainerSum))
                    .fixedSize(horizontal: false, vertical: true)

                DisclosureGroup(loc.t(.tlPhrasesCounted, TicLexicon.words.count)) {
                    ScrollView {
                        Text(TicLexicon.words.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxHeight: 140)
                }

                Text(loc.t(.tlExplainerThreshold, weightString(ContaminationScan.zThreshold),
                           baselineYear, ContaminationScan.sustainedMonths))
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Text(loc.t(.tlExplainerNotTitle))
                    .font(.subheadline.weight(.semibold))
                VStack(alignment: .leading, spacing: 4) {
                    Text(loc.t(.tlNotDetector))
                    Text(loc.t(.tlNotCloud))
                    Text(loc.t(.tlNotSentenceLength))
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
        .frame(width: 360, height: 420)
    }

    private var baselineYear: String {
        String(ContaminationScan.baselineEraCutoff.prefix(4))
    }

    /// Renders a weight as "1" instead of "1.0" when it's a whole number —
    /// reads more naturally in prose ("weight ×1") without implying false
    /// precision on the ones that aren't whole (there currently aren't any,
    /// but this keeps the formatting honest if that changes).
    private func weightString(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
