import CCKit
import SwiftUI
import UniformTypeIdentifiers

struct DecisionCaption: View {
    let entry: DecisionEntry

    private var copy: String {
        decisionText(entry, timeZone: TimeZone(identifier: "Australia/Sydney")!, locale: Locale(identifier: "en_AU"))
    }

    private var symbol: String {
        switch entry.behavior {
        case .allow, .allowSession: "checkmark.circle.fill"
        case .deny: "xmark.circle.fill"
        case .timeout: "terminal"
        default: "checkmark.circle"
        }
    }

    private var color: Color {
        switch entry.behavior {
        case .allow, .allowSession: .ccGreen
        case .deny: .ccRed
        case .timeout: .ccAccent
        default: .ccSecondary
        }
    }

    var body: some View {
        CaptionRow(symbol: symbol, text: copy, symbolColor: color)
    }
}

struct CaptionRow: View {
    let symbol: String
    let text: String
    let symbolColor: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(symbolColor)
            Text(text)
                .foregroundStyle(.ccSecondary)
                .multilineTextAlignment(.center)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 8)
    }
}

struct CompactionDivider: View {
    let entry: CompactionEntry

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Rectangle()
                    .fill(.ccSeparator)
                    .frame(height: 1)
                caption
                    .fixedSize()
                Rectangle()
                    .fill(.ccSeparator)
                    .frame(height: 1)
            }
            .padding(.horizontal, 8)

            caption
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity)
    }

    private var caption: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.caption)
                .foregroundStyle(.ccSecondary)
            Text(entry.text ?? "Context compacted")
                .font(.caption)
                .foregroundStyle(.ccSecondary)
        }
    }
}

struct FileEntryView: View {
    let entry: FileEntry

    private var fileName: String { entry.name ?? "Untitled file" }
    private var isImage: Bool {
        (entry.mime ?? "").hasPrefix("image/") || fileName.lowercased().hasSuffix(".png")
    }

    var body: some View {
        if isImage {
            MockImageThumbnail(resourceName: "rollout", contentMode: .fit, cornerRadius: 12)
                .frame(width: 220, height: 477)
        } else {
            HStack(spacing: 10) {
                Image(systemName: fileSymbol)
                    .font(.title3)
                    .foregroundStyle(.ccSecondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(fileName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.ccLabel)
                    Text(formatSize(entry.size ?? 0))
                        .font(.caption)
                        .foregroundStyle(.ccSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(.ccCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var fileSymbol: String {
        if let type = UTType(mimeType: entry.mime ?? "") {
            if type.conforms(to: .spreadsheet) { return "tablecells" }
            if type.conforms(to: .commaSeparatedText) { return "tablecells" }
            if type.conforms(to: .text) { return "doc.text" }
        }
        return "doc"
    }
}

struct WorkedFooter: View {
    let durationMs: Int

    var body: some View {
        HStack(spacing: 6) {
            Text("✻")
                .foregroundStyle(.ccAccent)
            Text("Worked for \(displayDuration(durationMs))")
                .foregroundStyle(.ccSecondary)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, -8)
    }
}

struct MockImageThumbnail: View {
    let resourceName: String
    let contentMode: ContentMode
    let cornerRadius: CGFloat

    var body: some View {
        Image(resourceName, bundle: .main)
            .resizable()
            .aspectRatio(contentMode: contentMode)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .accessibilityLabel(resourceName)
    }
}

extension JSONValue {
    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
}
