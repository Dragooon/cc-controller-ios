import CCKit
import SwiftUI

/// Per-session answers in progress, kept outside the card so a rejected answer comes back with its draft intact
/// (the store drops the approval the moment an answer is sent and restores it on failure).
@MainActor @Observable
final class QuestionCardState {
    private var drafts: [String: QuestionAnswerDraft] = [:]
    private var visibleIndexes: [String: Int] = [:]
    private var otherEditing: [String: Set<Int>] = [:]
    private var errors: [String: String] = [:]
    private var readOnlyReasons: [String: String] = [:]

    func draft(for approval: Approval, questions: [Question]) -> QuestionAnswerDraft {
        drafts[key(approval)] ?? QuestionAnswerDraft(questions: questions)
    }

    func setDraft(_ draft: QuestionAnswerDraft, for approval: Approval) {
        drafts[key(approval)] = draft
    }

    func visibleIndex(for approval: Approval) -> Int {
        visibleIndexes[key(approval)] ?? 0
    }

    func setVisibleIndex(_ index: Int, for approval: Approval) {
        visibleIndexes[key(approval)] = index
    }

    func isEditingOther(_ index: Int, for approval: Approval) -> Bool {
        otherEditing[key(approval)]?.contains(index) == true
    }

    func setEditingOther(_ editing: Bool, at index: Int, for approval: Approval) {
        var indexes = otherEditing[key(approval)] ?? []
        if editing { indexes.insert(index) } else { indexes.remove(index) }
        otherEditing[key(approval)] = indexes
    }

    func error(for approval: Approval) -> String? {
        errors[key(approval)]
    }

    func setError(_ message: String?, for approval: Approval) {
        errors[key(approval)] = message
    }

    /// A hold that expired, or an answer the daemon will only take in the terminal, makes the card read-only.
    func readOnlyReason(for approval: Approval) -> String? {
        readOnlyReasons[key(approval)]
    }

    func setReadOnly(_ reason: String, for approval: Approval) {
        readOnlyReasons[key(approval)] = reason
    }

    func forget(_ approval: Approval) {
        let key = key(approval)
        drafts.removeValue(forKey: key)
        visibleIndexes.removeValue(forKey: key)
        otherEditing.removeValue(forKey: key)
        errors.removeValue(forKey: key)
        readOnlyReasons.removeValue(forKey: key)
    }

    private func key(_ approval: Approval) -> String {
        approvalDecisionKey(approval) ?? approval.requestId ?? "question"
    }
}

/// The AskUserQuestion card. It takes the approval card's slot in the session screen.
struct QuestionCard: View {
    let approval: Approval
    let questions: [Question]
    let state: QuestionCardState
    let canAnswer: Bool
    let onSend: ([String: String]) -> Void
    let onSkip: () -> Void
    let glassNamespace: Namespace.ID?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var actionHeight = CCMetrics.actionHeight
    @FocusState private var otherFieldFocused: Bool

    private var draft: QuestionAnswerDraft { state.draft(for: approval, questions: questions) }
    private var visibleIndex: Int { min(state.visibleIndex(for: approval), questions.count - 1) }
    private var question: Question { questions[visibleIndex] }

    /// Nil while the card can be answered here; otherwise the read-only line that replaces its buttons.
    private var readOnlyReason: String? {
        if let answerIn = answerInLabel(for: approval) { return answerIn }
        if !canAnswer { return "Answer in Discord" }
        if approval.mode == .terminal || approval.status == .terminal { return "Answer in the terminal" }
        return state.readOnlyReason(for: approval)
    }

    var body: some View {
        Group {
            if let glassNamespace {
                card.glassEffectID("composer", in: glassNamespace)
            } else {
                card
            }
        }
    }

    private var card: some View {
        ViewThatFits(in: .vertical) {
            VStack(alignment: .leading, spacing: 12) {
                cardBody
                actions
            }
            VStack(alignment: .leading, spacing: 12) {
                ScrollView(.vertical) {
                    cardBody
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: .infinity)
                actions
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(14)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 26))
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Question: \(question.header)")
        .accessibilityIdentifier("question-card")
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            if questions.count > 1 {
                chips
            } else {
                Text(question.header)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.ccSecondary)
            }

            Text(question.question)
                .font(.body)
                .foregroundStyle(.ccLabel)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("question-text")

            if question.multiSelect {
                Text("Choose any that apply.")
                    .font(.caption)
                    .foregroundStyle(.ccSecondary)
            }

            VStack(spacing: 6) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                    optionRow(option)
                }
                otherRow
            }
            .disabled(readOnlyReason != nil)

            if let error = state.error(for: approval) {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.ccRed)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("question-error")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(Array(questions.enumerated()), id: \.offset) { index, item in
                    let answered = draft.answers[item.question] != nil
                    Button {
                        otherFieldFocused = false
                        state.setVisibleIndex(index, for: approval)
                    } label: {
                        HStack(spacing: 4) {
                            if answered {
                                Image(systemName: "checkmark")
                                    .font(.caption2.weight(.bold))
                            }
                            Text(item.header)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                        }
                        .foregroundStyle(index == visibleIndex ? Color.white : Color.ccLabel)
                        .padding(.horizontal, 10)
                        .frame(minHeight: CCMetrics.chipHeight)
                        .background(index == visibleIndex ? Color.ccAccent : Color.ccSecondary.opacity(0.12), in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: CCMetrics.minTap)
                    .accessibilityIdentifier("question-chip-\(index)")
                    .accessibilityLabel(item.header)
                    .accessibilityValue(answered ? "Answered" : "Not answered")
                    .accessibilityAddTraits(index == visibleIndex ? .isSelected : [])
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func optionRow(_ option: QuestionOption) -> some View {
        let selected = draft.selections[visibleIndex]?.selectedLabels.contains(option.label) == true
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                choose(option)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: selectionSymbol(selected: selected))
                        .font(.body)
                        .foregroundStyle(selected ? Color.ccAccent : Color.ccTertiary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.label)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.ccLabel)
                            .fixedSize(horizontal: false, vertical: true)
                        if !option.description.isEmpty {
                            Text(option.description)
                                .font(.footnote)
                                .foregroundStyle(.ccSecondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: CCMetrics.minTap, alignment: .leading)
                .background(selected ? Color.ccAccent.opacity(0.12) : Color.ccSecondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(option.description.isEmpty ? option.label : "\(option.label), \(option.description)")
            .accessibilityValue(selected ? "Selected" : "Not selected")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("question-option-\(option.label)")

            if let preview = option.preview, !preview.isEmpty {
                DisclosureGroup("Preview") {
                    ScrollView(.vertical) {
                        Text(preview)
                            .font(.caption.monospaced())
                            .foregroundStyle(.ccLabel)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: previewMaxHeight)
                }
                .font(.footnote.weight(.medium))
                .tint(.ccAccent)
                .padding(.horizontal, 10)
                .accessibilityIdentifier("question-preview-\(option.label)")
            }
        }
    }

    @ViewBuilder
    private var otherRow: some View {
        let editing = state.isEditingOther(visibleIndex, for: approval)
        let otherText = draft.selections[visibleIndex]?.otherText
        if editing {
            TextField("Type your answer", text: otherBinding)
                .font(.subheadline)
                .focused($otherFieldFocused)
                .submitLabel(.done)
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .frame(minHeight: CCMetrics.minTap)
                .background(Color.ccSecondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityIdentifier("question-other-field")
                .onSubmit { otherFieldFocused = false }
        } else {
            Button {
                state.setEditingOther(true, at: visibleIndex, for: approval)
                otherFieldFocused = true
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: selectionSymbol(selected: otherText != nil))
                        .foregroundStyle(otherText != nil ? Color.ccAccent : Color.ccTertiary)
                        .accessibilityHidden(true)
                    Text(otherText ?? "Other")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.ccLabel)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: CCMetrics.minTap, alignment: .leading)
                .background(Color.ccSecondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Other")
            .accessibilityValue(otherText ?? "")
            .accessibilityIdentifier("question-other")
        }
    }

    private var actions: some View {
        VStack(spacing: 4) {
            if let readOnlyReason {
                Text(readOnlyReason)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.ccSecondary)
                    .frame(maxWidth: .infinity, minHeight: CCMetrics.minTap)
                    .accessibilityIdentifier("question-read-only")
            } else {
                Button {
                    otherFieldFocused = false
                    guard let answers = draft.validatedAnswers else { return }
                    state.setError(nil, for: approval)
                    onSend(answers)
                } label: {
                    Text(questions.count > 1 ? "Send answers" : "Send answer")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: visibleActionHeight, maxHeight: visibleActionHeight)
                        .glassEffect(.regular.tint(draft.isComplete ? .ccAccent : .ccTertiary).interactive(), in: .capsule)
                }
                .buttonStyle(.plain)
                .disabled(!draft.isComplete)
                .frame(maxWidth: .infinity, minHeight: CCMetrics.minTap)
                .contentShape(Rectangle())
                .accessibilityIdentifier("question-send")

                Button {
                    otherFieldFocused = false
                    state.setError(nil, for: approval)
                    onSkip()
                } label: {
                    Text("Skip")
                        .frame(maxWidth: .infinity, minHeight: CCMetrics.minTap)
                        .contentShape(Rectangle())
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.ccSecondary)
                .buttonStyle(.plain)
                .accessibilityIdentifier("question-skip")
            }
        }
    }

    private var otherBinding: Binding<String> {
        Binding(
            get: { draft.selections[visibleIndex]?.otherText ?? "" },
            set: { text in
                var updated = draft
                if updated.setOtherText(text, at: visibleIndex) {
                    state.setDraft(updated, for: approval)
                }
            }
        )
    }

    private func choose(_ option: QuestionOption) {
        otherFieldFocused = false
        var updated = draft
        if question.multiSelect {
            updated.toggleOption(option.label, at: visibleIndex)
            state.setDraft(updated, for: approval)
            return
        }
        let next = updated.selectSingleOption(option.label, at: visibleIndex)
        state.setDraft(updated, for: approval)
        state.setEditingOther(false, at: visibleIndex, for: approval)
        if let next {
            withAnimation(.snappy) {
                state.setVisibleIndex(next, for: approval)
            }
        }
    }

    private func selectionSymbol(selected: Bool) -> String {
        if question.multiSelect {
            return selected ? "checkmark.square.fill" : "square"
        }
        return selected ? "largecircle.fill.circle" : "circle"
    }

    private var visibleActionHeight: CGFloat {
        min(actionHeight, 56)
    }

    /// About eight lines of caption monospace.
    private var previewMaxHeight: CGFloat {
        dynamicTypeSize >= .xxLarge ? 200 : 136
    }
}

/// Every question of an answered (or pending) AskUserQuestion entry, with the chosen answer marked.
struct QuestionAnswerSheet: View {
    let model: QuestionSheetModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(Array(model.questions.enumerated()), id: \.offset) { _, detail in
                        questionSection(detail)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 20)
            }
            .background(.ccBackground)
            .navigationTitle(model.questions.count > 1 ? "Questions" : "Question")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .accessibilityIdentifier("question-sheet")
    }

    private func questionSection(_ detail: QuestionAnswerDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(detail.question.header)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.ccSecondary)
            Text(detail.question.question)
                .font(.body)
                .foregroundStyle(.ccLabel)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(detail.question.options.enumerated()), id: \.offset) { _, option in
                let chosen = detail.selectedOptionLabels.contains(option.label)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(chosen ? Color.ccAccent : Color.ccTertiary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.label)
                            .font(.subheadline.weight(chosen ? .semibold : .regular))
                            .foregroundStyle(.ccLabel)
                        if !option.description.isEmpty {
                            Text(option.description)
                                .font(.footnote)
                                .foregroundStyle(.ccSecondary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(chosen ? "Chosen" : "")
            }
            if let otherText = detail.otherText {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.ccAccent)
                        .accessibilityHidden(true)
                    Text("Other: \(otherText)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.ccLabel)
                }
                .accessibilityElement(children: .combine)
            }
            if detail.answer == nil {
                Text("Not answered yet")
                    .font(.footnote)
                    .foregroundStyle(.ccSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
