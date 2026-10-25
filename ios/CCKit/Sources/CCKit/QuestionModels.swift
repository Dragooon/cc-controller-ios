import Foundation

public enum ApprovalKind: Codable, Sendable, Equatable {
    case generic
    case question
    case unknown(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = (try? container.decode(String.self)) ?? "generic"
        switch value {
        case "generic": self = .generic
        case "question": self = .question
        default: self = .unknown(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var rawValue: String {
        switch self {
        case .generic: "generic"
        case .question: "question"
        case .unknown(let value): value
        }
    }
}

public struct QuestionOption: Codable, Sendable, Equatable {
    public let label: String
    public let description: String
    public let preview: String?

    public init(label: String, description: String, preview: String? = nil) {
        self.label = label
        self.description = description
        self.preview = preview
    }
}

public struct Question: Codable, Sendable, Equatable {
    public let question: String
    public let header: String
    public let options: [QuestionOption]
    public let multiSelect: Bool

    public init(question: String, header: String, options: [QuestionOption], multiSelect: Bool) {
        self.question = question
        self.header = header
        self.options = options
        self.multiSelect = multiSelect
    }
}

public extension Approval {
    var questions: [Question]? {
        guard kind == .question else { return nil }
        return parseQuestionItems(from: toolInput)
    }
}

private func parseQuestionItems(from input: JSONValue?) -> [Question]? {
    guard case .object(let object) = input,
          case .array(let rawQuestions)? = object["questions"],
          (1...4).contains(rawQuestions.count) else { return nil }

    let parsed = rawQuestions.compactMap { rawQuestion -> Question? in
        guard case .object(let value) = rawQuestion,
              let question = value["question"]?.stringValue,
              !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let header = value["header"]?.stringValue,
              case .array(let rawOptions)? = value["options"],
              (2...4).contains(rawOptions.count) else { return nil }
        let multiSelect: Bool
        if let rawMultiSelect = value["multiSelect"] {
            guard case .bool(let value) = rawMultiSelect else { return nil }
            multiSelect = value
        } else {
            multiSelect = false
        }
        let options = rawOptions.compactMap { rawOption -> QuestionOption? in
            guard case .object(let option) = rawOption,
                  let label = option["label"]?.stringValue else { return nil }
            return QuestionOption(
                label: label,
                description: option["description"]?.stringValue ?? "",
                preview: option["preview"]?.stringValue
            )
        }
        guard options.count == rawOptions.count else { return nil }
        return Question(question: question, header: header, options: options, multiSelect: multiSelect)
    }
    return parsed.count == rawQuestions.count ? parsed : nil
}

public struct QuestionSelection: Sendable, Equatable {
    public fileprivate(set) var selectedLabels: Set<String>
    public fileprivate(set) var otherText: String?

    public init(selectedLabels: Set<String> = [], otherText: String? = nil) {
        self.selectedLabels = selectedLabels
        self.otherText = otherText
    }
}

public struct QuestionAnswerDraft: Sendable, Equatable {
    public let questions: [Question]
    private var values: [QuestionSelection?]

    public init(questions: [Question]) {
        self.questions = questions
        values = Array(repeating: nil, count: questions.count)
    }

    public var selections: [QuestionSelection?] { values }

    public var isComplete: Bool {
        questions.indices.allSatisfy { encodedAnswer(at: $0) != nil }
    }

    /// The currently valid answers. Incomplete drafts contain only answered questions.
    public var answers: [String: String] {
        Dictionary(uniqueKeysWithValues: questions.indices.compactMap { index in
            guard let answer = encodedAnswer(at: index) else { return nil }
            return (questions[index].question, answer)
        })
    }

    public var validatedAnswers: [String: String]? {
        guard isComplete else { return nil }
        return answers
    }

    /// Selects a single-select option and returns the next unanswered question index.
    @discardableResult
    public mutating func selectSingleOption(_ label: String, at index: Int) -> Int? {
        guard questions.indices.contains(index), !questions[index].multiSelect,
              questions[index].options.contains(where: { $0.label == label }) else { return nil }
        values[index] = QuestionSelection(selectedLabels: [label])
        return nextUnansweredQuestionIndex(after: index)
    }

    public mutating func toggleOption(_ label: String, at index: Int) {
        guard questions.indices.contains(index), questions[index].multiSelect,
              questions[index].options.contains(where: { $0.label == label }) else { return }
        var selection = values[index] ?? QuestionSelection()
        if selection.selectedLabels.contains(label) {
            selection.selectedLabels.remove(label)
        } else {
            selection.selectedLabels.insert(label)
        }
        values[index] = selection
    }

    @discardableResult
    public mutating func setOtherText(_ text: String, at index: Int) -> Bool {
        guard questions.indices.contains(index) else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty || trimmed.count <= 2_000 else { return false }
        var selection = values[index] ?? QuestionSelection()
        selection.otherText = trimmed.isEmpty ? nil : trimmed
        if !questions[index].multiSelect { selection.selectedLabels.removeAll() }
        values[index] = selection
        return true
    }

    public mutating func clearAnswer(at index: Int) {
        guard questions.indices.contains(index) else { return }
        values[index] = nil
    }

    public func nextUnansweredQuestionIndex(after index: Int? = nil) -> Int? {
        let start = index.map { $0 + 1 } ?? 0
        if let next = questions.indices.dropFirst(start).first(where: { encodedAnswer(at: $0) == nil }) { return next }
        if index == nil, let first = questions.indices.first(where: { encodedAnswer(at: $0) == nil }) { return first }
        return nil
    }

    private func encodedAnswer(at index: Int) -> String? {
        guard questions.indices.contains(index), let selection = values[index] else { return nil }
        let question = questions[index]
        var labels = question.options
            .filter { selection.selectedLabels.contains($0.label) }
            .map(\.label)
        if let otherText = selection.otherText, !otherText.isEmpty { labels.append(otherText) }
        let answer = labels.joined(separator: ", ")
        guard !answer.isEmpty, answer.count <= 2_000 else { return nil }
        return answer
    }
}

public struct QuestionAnswerDetail: Sendable, Equatable {
    public let question: Question
    public let selectedOptionLabels: [String]
    public let otherText: String?
    public let answer: String?

    public init(question: Question, answer: String?) {
        self.question = question
        self.answer = answer
        guard let answer, !answer.isEmpty else {
            selectedOptionLabels = []
            otherText = nil
            return
        }
        if !question.multiSelect {
            if let option = question.options.first(where: { $0.label == answer }) {
                selectedOptionLabels = [option.label]
                otherText = nil
            } else {
                selectedOptionLabels = []
                otherText = answer
            }
            return
        }

        let segments = answer.components(separatedBy: ", ")
        var used = Set<Int>()
        var selected: [String] = []
        for option in question.options {
            let optionSegments = option.label.components(separatedBy: ", ")
            guard let range = segmentRange(optionSegments, in: segments, excluding: used) else { continue }
            selected.append(option.label)
            used.formUnion(range)
        }
        selectedOptionLabels = selected
        let remainder = segments.enumerated().compactMap { used.contains($0.offset) ? nil : $0.element }
        otherText = remainder.isEmpty ? nil : remainder.joined(separator: ", ")
    }
}

private func segmentRange(_ target: [String], in segments: [String], excluding used: Set<Int>) -> Range<Int>? {
    guard !target.isEmpty, target.count <= segments.count else { return nil }
    for start in 0...(segments.count - target.count) {
        let end = start + target.count
        guard Set(start..<end).isDisjoint(with: used), Array(segments[start..<end]) == target else { continue }
        return start..<end
    }
    return nil
}

public struct QuestionSheetModel: Sendable, Equatable {
    public let questions: [QuestionAnswerDetail]

    public init(questions: [QuestionAnswerDetail]) {
        self.questions = questions
    }
}

public func questionSheetModel(for entry: ToolEntry) -> QuestionSheetModel? {
    guard let questions = parseQuestionItems(from: entry.args), entry.tool == "AskUserQuestion" else { return nil }
    let answers = structuredQuestionAnswers(in: entry.toolUseResult) ?? parsedQuestionAnswers(entry.result)
    return QuestionSheetModel(questions: questions.map { QuestionAnswerDetail(question: $0, answer: answers?[$0.question]) })
}

public struct QuestionTranscriptRow: Sendable, Equatable {
    public let text: String
    public let detail: QuestionSheetModel?
    public let pending: Bool

    public init(text: String, detail: QuestionSheetModel? = nil, pending: Bool) {
        self.text = text
        self.detail = detail
        self.pending = pending
    }
}

public func questionTranscriptRow(for entry: ToolEntry) -> QuestionTranscriptRow? {
    guard entry.tool == "AskUserQuestion",
          let questions = parseQuestionItems(from: entry.args) else { return nil }
    let headers = questions.map(\.header).joined(separator: "; ")
    let detail = questionSheetModel(for: entry)
    if entry.state == .running || (entry.result == nil && entry.toolUseResult == nil) {
        return QuestionTranscriptRow(text: "Asking: \(headers)", detail: detail, pending: true)
    }
    if isDeclinedQuestionResult(entry) {
        let text = questions.map { "\($0.header) · Declined" }.joined(separator: "; ")
        return QuestionTranscriptRow(text: text, detail: detail, pending: false)
    }
    if let answers = structuredQuestionAnswers(in: entry.toolUseResult) ?? parsedQuestionAnswers(entry.result) {
        let answerText = questions.map { "\($0.header) · \(answers[$0.question] ?? "Answered")" }.joined(separator: "; ")
        return QuestionTranscriptRow(text: answerText, detail: detail, pending: false)
    }
    let text = questions.map { "\($0.header) · Answered" }.joined(separator: "; ")
    return QuestionTranscriptRow(text: text, detail: detail, pending: false)
}

public func questionTranscriptText(for entry: ToolEntry) -> String? {
    questionTranscriptRow(for: entry)?.text
}

private func structuredQuestionAnswers(in value: JSONValue?) -> [String: String]? {
    guard case .object(let object) = value,
          case .object(let rawAnswers)? = object["answers"] else { return nil }
    let answers = rawAnswers.compactMapValues(\.stringValue)
    return answers.isEmpty ? nil : answers
}

private func parsedQuestionAnswers(_ result: String?) -> [String: String]? {
    guard let result, result.contains("Your questions have been answered:") else { return nil }
    let pattern = #"\"((?:\\.|[^\"])*)\"=\"((?:\\.|[^\"])*)\""#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(result.startIndex..<result.endIndex, in: result)
    let values = regex.matches(in: result, range: range).compactMap { match -> (String, String)? in
        guard match.numberOfRanges == 3,
              let questionRange = Range(match.range(at: 1), in: result),
              let answerRange = Range(match.range(at: 2), in: result) else { return nil }
        return (unescapeTranscriptString(String(result[questionRange])), unescapeTranscriptString(String(result[answerRange])))
    }
    guard !values.isEmpty else { return nil }
    return Dictionary(uniqueKeysWithValues: values)
}

private func unescapeTranscriptString(_ value: String) -> String {
    guard let data = "\"\(value)\"".data(using: .utf8),
          let decoded = try? JSONSerialization.jsonObject(with: data) as? String else { return value }
    return decoded
}

private func isDeclinedQuestionResult(_ entry: ToolEntry) -> Bool {
    if entry.result?.contains("The user declined to answer") == true { return true }
    if case .string(let value)? = entry.toolUseResult { return value.contains("The user declined to answer") }
    return false
}

public func approvalCaption(_ approval: Approval) -> String {
    if let header = approval.questions?.first?.header {
        return "Asking: \(header)"
    }
    return permissionCopy(approval).header
}

public func sessionListCaption(_ session: Session) -> String? {
    guard let approval = session.pending?.first else { return nil }
    return approval.questions == nil ? nil : approvalCaption(approval)
}
