import SwiftUI

struct FilteredPanel: View {
    let perDropReason: [String: Int]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(perDropReason.sorted { $0.value > $1.value }, id: \.key) { reason, count in
                HStack {
                    Text(ItemQuery.humanLabel(forDropReason: reason))
                    Spacer()
                    Text(count.formatted()).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
        }
    }
}
