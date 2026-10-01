import CCKit
import SwiftUI
import UIKit

struct ToolDetailSheet: View {
    let tool: ToolEntry
    @Environment(\.dismiss) private var dismiss

    private var toolName: String { tool.tool ?? "Tool" }
    private var inputObject: [String: JSONValue] {
        guard case .object(let object) = tool.args else { return [:] }
        return object
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    statusSection
                    detailSections
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 20)
            }
            .background(.ccBackground)
            .navigationTitle(toolName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .close) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(copySections) { section in
                            Button("Copy \(section.title.lowercased())") {
                                UIPasteboard.general.string = section.value
                            }
                        }
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }
            }
        }
        .tint(.ccAccent)
    }

    private var statusSection: some View {
        ToolDetailSection(title: "Status") {
            HStack(spacing: 8) {
                Image(systemName: statusSymbol)
                    .foregroundStyle(statusColor)
                Text(statusText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.ccLabel)
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var detailSections: some View {
        switch toolName {
        case "Bash":
            ToolDetailSection(title: "Input") {
                SelectableCodePanel(text: inputObject["command"]?.stringValue ?? toolArgument(toolName, args: tool.args))
            }
            ToolDetailSection(title: "Output") {
                SelectableCodePanel(text: outputText)
            }
        case "Edit", "MultiEdit":
            ToolDetailSection(title: "File") {
                SelectableTextPanel(text: filePathText)
            }
            ToolDetailSection(title: "Changes") {
                DiffPanel(lines: editDiff)
            }
        case "Write":
            ToolDetailSection(title: "File") {
                SelectableTextPanel(text: filePathText)
            }
            ToolDetailSection(title: "Changes") {
                SelectableCodePanel(text: inputObject["content"]?.stringValue ?? outputText)
            }
        case "Read":
            ToolDetailSection(title: "File") {
                SelectableTextPanel(text: filePathText)
            }
            ToolDetailSection(title: "Output") {
                SelectableCodePanel(text: outputText)
            }
        default:
            ToolDetailSection(title: "Input") {
                SelectableCodePanel(text: prettyJSON(tool.args))
            }
            ToolDetailSection(title: "Output") {
                SelectableCodePanel(text: outputText)
            }
        }
    }

    private var copySections: [ToolDetailCopySection] {
        switch toolName {
        case "Bash":
            return [
                ToolDetailCopySection(title: "Input", value: inputObject["command"]?.stringValue ?? toolArgument(toolName, args: tool.args)),
                ToolDetailCopySection(title: "Output", value: outputText),
            ]
        case "Edit", "MultiEdit":
            return [
                ToolDetailCopySection(title: "File", value: filePathText),
                ToolDetailCopySection(title: "Changes", value: editDiff.map(\.copyText).joined(separator: "\n")),
            ]
        case "Write":
            return [
                ToolDetailCopySection(title: "File", value: filePathText),
                ToolDetailCopySection(title: "Changes", value: inputObject["content"]?.stringValue ?? outputText),
            ]
        case "Read":
            return [
                ToolDetailCopySection(title: "File", value: filePathText),
                ToolDetailCopySection(title: "Output", value: outputText),
            ]
        default:
            return [
                ToolDetailCopySection(title: "Input", value: prettyJSON(tool.args)),
                ToolDetailCopySection(title: "Output", value: outputText),
            ]
        }
    }

    private var filePathText: String {
        inputObject["file_path"]?.stringValue
            ?? inputObject["path"]?.stringValue
            ?? "Unknown file"
    }

    private var outputText: String {
        let output = tool.result ?? tool.text ?? ""
        return output.isEmpty ? "No output" : output
    }

    private var statusText: String {
        let state: String
        switch tool.state {
        case .running: state = "Running"
        case .done, nil: state = "Done"
        case .unknown(let value): state = value.capitalized
        }
        guard let durationMs = tool.durationMs else { return state }
        return "\(state) · \(displayDuration(durationMs))"
    }

    private var statusSymbol: String {
        switch tool.state {
        case .running: "arrow.triangle.2.circlepath"
        case .unknown(let value) where value == "failed": "xmark.circle.fill"
        default: "checkmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch tool.state {
        case .running: .ccAccent
        case .unknown(let value) where value == "failed": .ccRed
        default: .ccGreen
        }
    }

    private var editDiff: [ToolDiffLine] {
        if toolName == "MultiEdit", let edits = inputObject["edits"], case .array(let values) = edits {
            return values.flatMap { value -> [ToolDiffLine] in
                guard case .object(let edit) = value else { return [] }
                return diffLines(old: edit["old_string"]?.stringValue ?? "", new: edit["new_string"]?.stringValue ?? "")
            }
        }
        return diffLines(
            old: inputObject["old_string"]?.stringValue ?? "",
            new: inputObject["new_string"]?.stringValue ?? ""
        )
    }

    private func diffLines(old: String, new: String) -> [ToolDiffLine] {
        let oldLines = old.components(separatedBy: .newlines)
        let newLines = new.components(separatedBy: .newlines)
        guard old != new else {
            return oldLines.map { ToolDiffLine(prefix: " ", text: $0, isRemoved: false) }
        }
        return oldLines.map { ToolDiffLine(prefix: "−", text: $0, isRemoved: true) }
            + newLines.map { ToolDiffLine(prefix: "+", text: $0, isRemoved: false) }
    }

    private func prettyJSON(_ value: JSONValue?) -> String {
        guard let value,
              let data = try? JSONEncoder.ccKit().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: pretty, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}

private struct ToolDetailCopySection: Identifiable {
    let title: String
    let value: String
    var id: String { title }
}

private struct ToolDiffLine {
    let prefix: String
    let text: String
    let isRemoved: Bool

    var copyText: String { "\(prefix)\(text)" }
}

private struct ToolDetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.ccSecondary)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SelectableTextPanel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote.monospaced())
            .foregroundStyle(.ccSecondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SelectableCodePanel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote.monospaced())
            .foregroundStyle(.ccLabel)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.ccCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct DiffPanel: View {
    let lines: [ToolDiffLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(line.prefix)
                        .foregroundStyle(line.isRemoved ? .ccRed : .ccGreen)
                        .frame(width: 14, alignment: .leading)
                    Text(line.text)
                        .foregroundStyle(.ccLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.footnote.monospaced())
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(line.isRemoved ? Color.ccRed.opacity(0.12) : Color.ccGreen.opacity(0.12))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .background(.ccCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .textSelection(.enabled)
    }
}
