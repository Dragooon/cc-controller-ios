import CCKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import QuickLook

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
    let onOpen: (CompactionEntry) -> Void

    init(entry: CompactionEntry, onOpen: @escaping (CompactionEntry) -> Void = { _ in }) {
        self.entry = entry
        self.onOpen = onOpen
    }

    private var hasSummary: Bool {
        !(entry.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            if hasSummary {
                Button { onOpen(entry) } label: {
                    dividerContent
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityLabel("Context compacted")
            } else {
                dividerContent
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var dividerContent: some View {
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

struct CompactionSummarySheet: View {
    let entry: CompactionEntry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                MarkdownView(markdown: entry.text ?? "")
                    .padding(20)
            }
            .background(.ccBackground)
            .navigationTitle("Context compacted")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .tint(.ccAccent)
    }
}

struct FileEntryView: View {
    let entry: FileEntry
    let download: (@MainActor @Sendable (FileEntry) async throws -> URL)?
    @State private var isDownloading = false
    @State private var previewURL: URL?
    @State private var errorMessage: String?

    init(entry: FileEntry, download: (@MainActor @Sendable (FileEntry) async throws -> URL)? = nil) {
        self.entry = entry
        self.download = download
    }

    private var fileName: String { entry.name ?? "Untitled file" }
    private var isImage: Bool {
        (entry.mime ?? "").lowercased().hasPrefix("image/") || isImageAttachmentName(fileName)
    }

    var body: some View {
        Button(action: beginDownload) {
            ZStack {
                fileTile
                if isDownloading {
                    ProgressView()
                        .controlSize(.small)
                        .padding(10)
                        .background(.regularMaterial, in: Capsule())
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(download == nil || isDownloading)
        .accessibilityLabel("Open \(fileName)")
        .quickLookPreview($previewURL)
        .alert(
            "Couldn't open file",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "The file could not be downloaded.")
        }
    }

    @ViewBuilder
    private var fileTile: some View {
        if isImage {
            RemoteFileImageTile(entry: entry, download: download)
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

    private func beginDownload() {
        guard let download, !isDownloading else { return }
        isDownloading = true
        Task { @MainActor in
            do {
                previewURL = try await download(entry)
            } catch {
                errorMessage = error.localizedDescription
            }
            isDownloading = false
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

extension JSONValue {
    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
}
