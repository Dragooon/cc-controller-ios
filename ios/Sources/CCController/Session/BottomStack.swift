import CCKit
import SwiftUI

struct SlashCommand: Identifiable {
    let command: String
    let description: String

    var id: String { command }
}

struct BottomStackConfiguration: @unchecked Sendable {
    let composer: ComposerConfiguration
    let statusSegments: [String]
    let slashCommands: [SlashCommand]
    let attachments: [ComposerAttachment]
    let approvals: [Approval]
    let deciding: Set<String>
    let onAllow: (Approval) -> Void
    let onAllowSession: (Approval) -> Void
    let onDeny: (Approval) -> Void

    init(
        composer: ComposerConfiguration = ComposerConfiguration(),
        statusSegments: [String] = [],
        slashCommands: [SlashCommand] = [],
        attachments: [ComposerAttachment] = [],
        approvals: [Approval] = [],
        deciding: Set<String> = [],
        onAllow: @escaping (Approval) -> Void = { _ in },
        onAllowSession: @escaping (Approval) -> Void = { _ in },
        onDeny: @escaping (Approval) -> Void = { _ in }
    ) {
        self.composer = composer
        self.statusSegments = statusSegments
        self.slashCommands = slashCommands
        self.attachments = attachments
        self.approvals = approvals
        self.deciding = deciding
        self.onAllow = onAllow
        self.onAllowSession = onAllowSession
        self.onDeny = onDeny
    }
}

struct BottomStackView: View {
    let configuration: BottomStackConfiguration
    @State private var text: String
    @FocusState private var composerFocused: Bool
    @Namespace private var glassNamespace

    init(configuration: BottomStackConfiguration) {
        self.configuration = configuration
        _text = State(initialValue: configuration.composer.initialText)
    }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                if !filteredCommands.isEmpty {
                    SlashSuggestionsView(commands: filteredCommands)
                }

                if !configuration.attachments.isEmpty {
                    AttachmentTrayView(attachments: configuration.attachments)
                }

                if !configuration.approvals.isEmpty {
                    ApprovalBottomStackView(
                        approvals: configuration.approvals,
                        deciding: configuration.deciding,
                        now: .now,
                        maxHeight: max(0, UIScreen.main.bounds.height - 180),
                        onAllow: configuration.onAllow,
                        onAllowSession: configuration.onAllowSession,
                        onDeny: configuration.onDeny,
                        glassNamespace: glassNamespace,
                        inGlassContainer: false
                    )
                }

                if !composerFocused, configuration.approvals.isEmpty, !configuration.statusSegments.isEmpty {
                    StatusLineView(segments: configuration.statusSegments)
                        .transition(.opacity)
                }

                if configuration.approvals.isEmpty {
                    ComposerView(
                        text: $text,
                        isFocused: $composerFocused,
                        configuration: configuration.composer,
                        glassNamespace: glassNamespace
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
        .background(.ccBackground.opacity(0.88))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bottom-stack")
        .onAppear {
            guard configuration.composer.focusesOnAppear else { return }
            DispatchQueue.main.async {
                composerFocused = true
            }
        }
    }

    private var filteredCommands: [SlashCommand] {
        guard text.hasPrefix("/") else { return [] }
        let prefix = text.split(whereSeparator: \ .isWhitespace).first.map(String.init) ?? text
        return configuration.slashCommands.filter { $0.command.lowercased().hasPrefix(prefix.lowercased()) }
    }
}

private struct SlashSuggestionsView: View {
    let commands: [SlashCommand]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(commands) { command in
                    Button {} label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(command.command)
                                .font(.footnote.monospaced())
                                .foregroundStyle(.ccLabel)
                            Text(command.description)
                                .font(.caption)
                                .foregroundStyle(.ccSecondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .accessibilityLabel("\(command.command), \(command.description)")
                }
            }
            .padding(.horizontal, 1)
        }
        .scrollIndicators(.hidden)
    }
}
