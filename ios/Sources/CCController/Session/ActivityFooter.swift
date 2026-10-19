import CCKit
import SwiftUI

struct LiveActivityFooterView: View {
    let footer: CCKit.ActivityFooter
    let session: Session?

    init(footer: CCKit.ActivityFooter, session: Session? = nil) {
        self.footer = footer
        self.session = session
    }

    var body: some View {
        #if CC_PERF
        let _ = PerfCounters.shared.hit(.activityFooter)
        #endif
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                SpinnerGlyph(active: session?.state == .working, frozen: false)
                    .font(.footnote)
                    .accessibilityHidden(true)
                primary
                    .font(.footnote)
                    .foregroundStyle(.ccLabel)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text(footer.detail)
                .font(.footnote.monospaced())
                .foregroundStyle(.ccSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(primaryText), \(footer.detail)")
    }

    @ViewBuilder
    private var primary: some View {
        if let session, session.state == .working, session.startedAt != nil, let verb {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(displayPrimary(activityFooterText(session, now: context.date, verb: verb).primary))
            }
        } else {
            Text(primaryText)
        }
    }

    private var primaryText: String {
        displayPrimary(footer.primary)
    }

    private func displayPrimary(_ value: String) -> String {
        value.hasPrefix("✻ ") ? String(value.dropFirst(2)) : value
    }

    private var verb: String? {
        guard let end = primaryText.firstIndex(of: "…") else { return nil }
        return String(primaryText[..<end])
    }
}
