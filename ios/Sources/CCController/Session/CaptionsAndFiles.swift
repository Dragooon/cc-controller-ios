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
        CaptionRow(symbol: symbol, text: copy, color: color)
    }
}

struct CaptionRow: View {
    let symbol: String
    let text: String
    let color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
            Text(text)
                .multilineTextAlignment(.center)
        }
        .font(.caption)
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 8)
    }
}

struct CompactionDivider: View {
    let entry: CompactionEntry

    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                Rectangle()
                    .fill(.ccSeparator)
                    .frame(height: 1)
                Rectangle()
                    .fill(.ccSeparator)
                    .frame(height: 1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.caption)
                    .foregroundStyle(.ccSecondary)
                ViewThatFits(in: .horizontal) {
                    Text(entry.text ?? "Context compacted")
                        .font(.caption)
                        .foregroundStyle(.ccSecondary)
                        .fixedSize()
                    Text("Context compacted")
                        .font(.caption)
                        .foregroundStyle(.ccSecondary)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 12)
            .background(.ccBackground)
        }
        .frame(maxWidth: .infinity)
    }
}

struct FileEntryView: View {
    let entry: FileEntry

    private var isImage: Bool { (entry.mime ?? "").hasPrefix("image/") }
    private var fileName: String { entry.name ?? "Untitled file" }

    var body: some View {
        if isImage {
            MockImageThumbnail(label: fileName)
                .frame(maxWidth: 220)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
            Text("Worked for \(formatDuration(Double(durationMs)))")
                .foregroundStyle(.ccSecondary)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, -8)
    }
}

struct MockImageThumbnail: View {
    let label: String

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [.ccBlue.opacity(0.85), .ccAccent.opacity(0.8), .ccGreen.opacity(0.7)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "photo")
                .font(.title2)
                .foregroundStyle(.white.opacity(0.9))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.black.opacity(0.4))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityLabel(label)
    }
}

extension JSONValue {
    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
}
