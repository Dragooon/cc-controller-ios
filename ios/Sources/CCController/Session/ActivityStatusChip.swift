import CCKit
import SwiftUI

/// Sits above the composer while agents or shells are running, and opens the activity sheet.
struct ActivityStatusChip: View {
    let session: Session
    let summary: String
    let onActivity: () -> Void

    var body: some View {
        Button(action: onActivity) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(summary)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.ccAccent)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.ccAccent)
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(.ccAccent.opacity(0.13), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Shows activity")
        .accessibilityIdentifier("activity-status")
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
    }

    private var accessibilityText: String {
        let counts = activityCounts(for: session)
        var parts: [String] = []
        if counts.agents > 0 { parts.append("\(counts.agents) agent\(counts.agents == 1 ? "" : "s")") }
        if counts.shells > 0 { parts.append("\(counts.shells) shell\(counts.shells == 1 ? "" : "s")") }
        return parts.joined(separator: " and ") + " running"
    }
}
