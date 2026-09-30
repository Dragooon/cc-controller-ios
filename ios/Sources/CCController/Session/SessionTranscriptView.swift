import CCKit
import SwiftUI
import UniformTypeIdentifiers

struct SessionTranscriptView: View {
    let turns: [Turn]
    let now: Date
    let showsComposer: Bool
    let showsWorkedFooter: Bool
    let onTool: (ToolEntry) -> Void
    let onSubagent: (SubagentEntry) -> Void

    init(
        turns: [Turn],
        now: Date,
        showsComposer: Bool = true,
        showsWorkedFooter: Bool = true,
        onTool: @escaping (ToolEntry) -> Void = { _ in },
        onSubagent: @escaping (SubagentEntry) -> Void = { _ in }
    ) {
        self.turns = turns
        self.now = now
        self.showsComposer = showsComposer
        self.showsWorkedFooter = showsWorkedFooter
        self.onTool = onTool
        self.onSubagent = onSubagent
    }

    @ViewBuilder
    var body: some View {
        if showsComposer {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    transcriptRows
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .background(.ccBackground)
            .safeAreaBar(edge: .bottom, spacing: 8) {
                ComposerPlaceholder()
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
            }
        } else {
            VStack(alignment: .leading, spacing: 20) {
                transcriptRows
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
            .background(.ccBackground)
        }
    }

    @ViewBuilder
    private var transcriptRows: some View {
        ForEach(turns) { turn in
            TranscriptTurnView(
                turn: turn,
                now: now,
                showsWorkedFooter: showsWorkedFooter,
                onTool: onTool,
                onSubagent: onSubagent
            )
            .id(turn.id)
        }
    }
}

struct ComposerPlaceholder: View {
    var body: some View {
        HStack {
            Text("Message")
                .font(.body)
                .foregroundStyle(.ccSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .accessibilityLabel("Message")
    }
}

struct TranscriptTurnView: View {
    let turn: Turn
    let now: Date
    let showsWorkedFooter: Bool
    let onTool: (ToolEntry) -> Void
    let onSubagent: (SubagentEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(Array(turn.prompts.enumerated()), id: \.offset) { _, prompt in
                PromptBubble(prompt: prompt)
            }

            ForEach(turn.items) { item in
                TurnItemView(item: item, now: now, onTool: onTool, onSubagent: onSubagent)
            }

            if showsWorkedFooter && turn.hasWorkedFooter {
                WorkedFooter(durationMs: turn.durationMs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PromptBubble: View {
    let prompt: PromptEntry
    @State private var isExpanded = false

    private var promptText: String {
        CCKit.normalisePromptText(prompt.text ?? prompt.command).text
    }

    private var collapse: PromptCollapse {
        promptCollapse(promptText, hasPaste: prompt.paste != nil)
    }

    private var attachmentNames: [String] {
        prompt.attachments ?? CCKit.normalisePromptText(prompt.text ?? prompt.command).attachments
    }

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 8) {
                if !attachmentNames.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(attachmentNames.enumerated()), id: \.offset) { _, name in
                            MockImageThumbnail(label: name)
                                .frame(width: 64, height: 64)
                        }
                    }
                }

                if let paste = prompt.paste {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.on.clipboard")
                        Text("pasted, \(paste.lines ?? paste.text?.components(separatedBy: .newlines).count ?? 0) lines")
                    }
                    .font(.footnote)
                    .foregroundStyle(.ccSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ccCard, in: Capsule())
                }

                if !promptText.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(isExpanded ? promptText : collapse.visibleText)
                            .font(.body)
                            .foregroundStyle(.ccLabel)
                            .multilineTextAlignment(.leading)
                            .textSelection(.enabled)

                        if collapse.collapsed && !isExpanded {
                            Button { isExpanded = true } label: {
                                Text("Show more")
                                    .font(.footnote)
                                    .foregroundStyle(.ccAccent)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .background(.ccBubble, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .containerRelativeFrame(.horizontal) { width, _ in width * 0.85 }
        }
    }
}

private struct TurnItemView: View {
    let item: TurnItem
    let now: Date
    let onTool: (ToolEntry) -> Void
    let onSubagent: (SubagentEntry) -> Void

    @ViewBuilder
    var body: some View {
        switch item {
        case .assistant(let entry):
            AssistantReplyView(text: entry.text ?? "")
        case .tools(let run):
            ToolRunCard(run: run, onTool: onTool)
        case .subagent(let entry):
            SubagentCard(entry: entry, now: now, onOpen: onSubagent)
        case .subagentResult(let entry):
            SubagentResultView(entry: entry)
        case .sendMessage(let entry):
            SendMessageView(entry: entry)
        case .decision(let entry):
            DecisionCaption(entry: entry)
        case .interrupt:
            CaptionRow(symbol: "stop.circle", text: "Interrupted", color: .ccSecondary)
        case .compaction(let entry):
            CompactionDivider(entry: entry)
        case .file(let entry):
            FileEntryView(entry: entry)
        case .other:
            EmptyView()
        }
    }
}

private struct AssistantReplyView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MarkdownView(markdown: text)
                .textSelection(.enabled)

            Button {} label: {
                Image(systemName: "doc.on.doc")
                    .font(.footnote)
                    .foregroundStyle(.ccSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copy reply")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ToolRunCard: View {
    let run: ToolRun
    let onTool: (ToolEntry) -> Void
    @State private var isExpanded: Bool

    init(run: ToolRun, onTool: @escaping (ToolEntry) -> Void) {
        self.run = run
        self.onTool = onTool
        _isExpanded = State(initialValue: run.isRunning)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if run.entries.count >= 2 {
                Button { isExpanded.toggle() } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(run.label)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.ccLabel)
                            Text(run.tallyText)
                                .font(.footnote)
                                .foregroundStyle(.ccSecondary)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.ccSecondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                if isExpanded {
                    Divider().overlay(.ccSeparator)
                }
            }

            if isExpanded || run.entries.count == 1 {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(run.entries.enumerated()), id: \.offset) { index, entry in
                        ToolRow(entry: entry, onOpen: onTool)
                        if index < run.entries.count - 1 {
                            Divider().overlay(.ccSeparator)
                                .padding(.leading, 38)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, run.entries.count == 1 ? 10 : 8)
            }
        }
        .background(.ccCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct ToolRow: View {
    let entry: ToolEntry
    let onOpen: (ToolEntry) -> Void

    private var state: ToolDisplayState {
        switch entry.state {
        case .running: .running
        case .done, nil: .done
        case .unknown(let value): value == "failed" ? .failed : .done
        }
    }

    var body: some View {
        Button { onOpen(entry) } label: {
            HStack(alignment: .top, spacing: 8) {
                ToolSymbol(tool: entry.tool ?? "Tool")
                    .font(.footnote)
                    .foregroundStyle(.ccSecondary)
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(entry.tool ?? "Tool")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.ccLabel)
                            .fixedSize(horizontal: true, vertical: false)
                        Text(toolArgument(entry.tool, args: entry.args))
                            .font(.footnote.monospaced())
                            .foregroundStyle(.ccSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ToolStatusView(state: state)
                    }
                    Text(firstMeaningfulLine(entry.result))
                        .font(.caption.monospaced())
                        .foregroundStyle(.ccSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(entry.tool ?? "Tool") \(toolArgument(entry.tool, args: entry.args))")
    }
}

private enum ToolDisplayState { case running, done, failed }

private struct ToolStatusView: View {
    let state: ToolDisplayState

    var body: some View {
        switch state {
        case .running:
            HStack(spacing: 4) {
                SpinnerGlyph(active: true, frozen: true, frozenColor: .ccAccent)
                Text("12s")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.ccAccent)
            }
        case .done:
            Image(systemName: "checkmark")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.ccGreen)
        case .failed:
            Image(systemName: "xmark")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.ccRed)
        }
    }
}

private struct SubagentCard: View {
    let entry: SubagentEntry
    let now: Date
    let onOpen: (SubagentEntry) -> Void

    private var state: SubagentState { entry.state ?? .done }
    private var durationText: String {
        guard let start = entry.startedAt else { return "0s" }
        let end = entry.finishedAt ?? now
        return formatDuration(max(0, end.timeIntervalSince(start) * 1000))
    }
    private var linked: Bool { !(entry.agentId ?? "").isEmpty }

    var body: some View {
        Button { onOpen(entry) } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    statusDot
                    Text(entry.agent ?? "agent")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.ccLabel)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(stateLabel) · \(durationText)")
                        .font(.caption)
                        .foregroundStyle(.ccSecondary)
                        .lineLimit(1)
                }
                Text(firstMeaningfulLine(entry.text))
                    .font(.footnote)
                    .foregroundStyle(.ccSecondary)
                    .lineLimit(1)
                if state == .done, !firstMeaningfulLine(entry.result).isEmpty {
                    Text(firstMeaningfulLine(entry.result))
                        .font(.footnote)
                        .foregroundStyle(.ccLabel)
                        .lineLimit(1)
                }
                if !linked {
                    Text("transcript not linked")
                        .font(.caption)
                        .foregroundStyle(.ccSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13)
            .background(.ccCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!linked)
        .opacity(linked ? 1 : 0.7)
        .overlay(alignment: .trailing) {
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.ccSecondary)
                .padding(.trailing, 14)
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        switch state {
        case .running:
            SpinnerGlyph(active: true, frozen: true)
                .font(.caption)
        case .done:
            Text("●")
                .foregroundStyle(.ccGreen)
        case .failed:
            Text("●")
                .foregroundStyle(.ccRed)
        case .stopped, .unknown:
            Text("●")
                .foregroundStyle(.ccSecondary)
        }
    }

    private var stateLabel: String {
        switch state {
        case .running: "Running"
        case .done: "Done"
        case .failed: "Failed"
        case .stopped: "Stopped"
        case .unknown: "Stopped"
        }
    }
}

private struct SubagentResultView: View {
    let entry: SubagentResultEntry
    @State private var isExpanded = false

    private var result: String { entry.result ?? entry.text ?? "" }
    private var durationText: String { formatDuration(Double(entry.durationMs ?? 0)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { isExpanded.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "arrowshape.turn.up.left")
                        .font(.footnote)
                        .foregroundStyle(.ccSecondary)
                    Text("\(entry.agent ?? "agent") replied · \(durationText)")
                        .font(.footnote)
                        .foregroundStyle(.ccSecondary)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.ccSecondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                MarkdownView(markdown: result)
                    .textSelection(.enabled)
            } else {
                Text(firstMeaningfulLine(result))
                    .font(.footnote)
                    .foregroundStyle(.ccLabel)
                    .lineLimit(1)
            }
        }
    }
}

private struct SendMessageView: View {
    let entry: ToolEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "arrow.right")
                .font(.footnote)
                .foregroundStyle(.ccSecondary)
            Text(formatSendMessage(args: entry.args?.objectValue ?? [:]))
                .font(.footnote)
                .foregroundStyle(.ccSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 3)
    }
}

private struct DecisionCaption: View {
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

private struct CaptionRow: View {
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

private struct CompactionDivider: View {
    let entry: CompactionEntry

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Rectangle().fill(.ccSeparator).frame(height: 1)
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.caption)
                .foregroundStyle(.ccSecondary)
            Text(entry.text ?? "Context compacted")
                .font(.caption)
                .foregroundStyle(.ccSecondary)
                .lineLimit(1)
            Rectangle().fill(.ccSeparator).frame(height: 1)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct FileEntryView: View {
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

private struct WorkedFooter: View {
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

private struct MockImageThumbnail: View {
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

private struct MarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownParser.blocks(markdown).enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum MarkdownBlock {
    case paragraph(String)
    case heading(String)
    case list([String])
    case code(String)
    case table([[String]])
}

private enum MarkdownParser {
    static func blocks(_ markdown: String) -> [MarkdownBlock] {
        let lines = markdown.components(separatedBy: .newlines)
        var result: [MarkdownBlock] = []
        var index = 0
        var paragraph: [String] = []

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { result.append(.paragraph(text)) }
            paragraph.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flushParagraph()
                index += 1
                var code: [String] = []
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                result.append(.code(code.joined(separator: "\n")))
                index += 1
                continue
            }
            if let heading = headingText(trimmed) {
                flushParagraph()
                result.append(.heading(heading))
                index += 1
                continue
            }
            if isTableLine(trimmed) {
                flushParagraph()
                var rows: [[String]] = []
                while index < lines.count, isTableLine(lines[index].trimmingCharacters(in: .whitespaces)) {
                    let row = tableCells(lines[index])
                    if !row.allSatisfy({ $0.range(of: "^[ :|\\-]+$", options: .regularExpression) != nil }) {
                        rows.append(row)
                    }
                    index += 1
                }
                if !rows.isEmpty { result.append(.table(rows)) }
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushParagraph()
                var items: [String] = []
                while index < lines.count {
                    let item = lines[index].trimmingCharacters(in: .whitespaces)
                    guard item.hasPrefix("- ") || item.hasPrefix("* ") else { break }
                    items.append(String(item.dropFirst(2)))
                    index += 1
                }
                result.append(.list(items))
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
            } else {
                paragraph.append(line)
            }
            index += 1
        }
        flushParagraph()
        return result
    }

    private static func headingText(_ line: String) -> String? {
        guard let range = line.range(of: "^#{1,6}\\s+", options: .regularExpression) else { return nil }
        return String(line[range.upperBound...])
    }

    private static func isTableLine(_ line: String) -> Bool {
        line.filter { $0 == "|" }.count >= 2
    }

    private static func tableCells(_ line: String) -> [String] {
        var cells = line.split(separator: "|", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
        if cells.first == "" { cells.removeFirst() }
        if cells.last == "" { cells.removeLast() }
        return cells
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .paragraph(let text):
            InlineMarkdownText(text: text)
        case .heading(let text):
            Text(markdownAttributed(text))
                .font(.body.weight(.semibold))
                .foregroundStyle(.ccLabel)
        case .list(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .foregroundStyle(.ccAccent)
                        InlineMarkdownText(text: item)
                    }
                }
            }
        case .code(let code):
            CodeBlockView(code: code)
        case .table(let rows):
            MarkdownTableView(rows: rows)
        }
    }
}

private struct InlineMarkdownText: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            ForEach(Array(inlineParts.enumerated()), id: \.offset) { _, part in
                if part.isCode {
                    Text(part.value)
                        .font(.body.monospaced())
                        .foregroundStyle(.ccLabel)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.ccCard, in: Capsule())
                } else {
                    Text(markdownAttributed(part.value))
                        .font(.body)
                        .foregroundStyle(.ccLabel)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var inlineParts: [InlinePart] {
        var parts: [InlinePart] = []
        var remainder = text[...]
        while let start = remainder.firstIndex(of: "`") {
            let before = String(remainder[..<start])
            if !before.isEmpty { parts.append(InlinePart(value: before, isCode: false)) }
            let afterStart = remainder.index(after: start)
            guard let end = remainder[afterStart...].firstIndex(of: "`") else {
                parts.append(InlinePart(value: String(remainder[start...]), isCode: false))
                remainder = ""
                break
            }
            parts.append(InlinePart(value: String(remainder[afterStart..<end]), isCode: true))
            remainder = remainder[remainder.index(after: end)...]
        }
        if !remainder.isEmpty { parts.append(InlinePart(value: String(remainder), isCode: false)) }
        return parts.isEmpty ? [InlinePart(value: text, isCode: false)] : parts
    }
}

private struct InlinePart {
    let value: String
    let isCode: Bool
}

private struct CodeBlockView: View {
    let code: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button {} label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(.ccSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copy code")

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.ccLabel)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(.ccCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct MarkdownTableView: View {
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(markdownAttributed(cell))
                                .font(.footnote)
                                .foregroundStyle(.ccLabel)
                                .frame(minWidth: 100, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                        }
                    }
                    if rowIndex < rows.count - 1 {
                        Rectangle().fill(.ccSeparator).frame(height: 1)
                    }
                }
            }
            .background(.ccCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

private func markdownAttributed(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text)) ?? AttributedString(text)
}

private extension JSONValue {
    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
}
