import Foundation
import XCTest
@testable import CCKit

final class QuestionTests: XCTestCase {
    func testApprovalDecodesQuestionKindAndQuestions() throws {
        let approval = try decodeApproval(kind: "question")
        XCTAssertEqual(approval.kind, .question)
        XCTAssertEqual(approval.questions?.map(\.header), ["One", "Many"])
        XCTAssertEqual(approval.questions?.last?.options.map(\.label), ["A", "B", "C"])
    }

    func testQuestionAccessorMatchesDaemonInputRules() throws {
        func approval(questions: [[String: Any]]) throws -> Approval {
            let value = try JSONSerialization.data(withJSONObject: ["kind": "question", "tool_name": "AskUserQuestion", "tool_input": ["questions": questions]])
            return try JSONDecoder.ccKit().decode(Approval.self, from: value)
        }
        let optionA: [String: Any] = ["label": "A", "description": "Choose A"]
        let optionB: [String: Any] = ["label": "B", "description": "Choose B"]
        let valid: [String: Any] = ["question": "Pick", "header": "Header", "options": [optionA, optionB], "multiSelect": false]
        XCTAssertNotNil(try approval(questions: [valid]).questions)
        XCTAssertNil(try approval(questions: []).questions)
        XCTAssertNil(try approval(questions: Array(repeating: valid, count: 5)).questions)
        XCTAssertNil(try approval(questions: [["question": "Pick", "header": "Header", "options": [optionA]]]).questions)
        XCTAssertNil(try approval(questions: [["question": "Pick", "header": "Header", "options": Array(repeating: optionA, count: 5)]]).questions)
        XCTAssertNil(try approval(questions: [["question": "Pick", "header": "Header", "options": [["description": "missing label"], optionB]]]).questions)
        XCTAssertNil(try approval(questions: [["question": "   ", "header": "Header", "options": [optionA, optionB]]]).questions)
        XCTAssertNil(try approval(questions: [["question": "Pick", "header": "Header", "options": [optionA, optionB], "multiSelect": "false"]]).questions)
    }

    func testQuestionAccessorAcceptsDaemonValidOptionalFields() throws {
        let data: [String: Any] = [
            "kind": "question",
            "tool_name": "AskUserQuestion",
            "tool_input": ["questions": [[
                "question": "Pick",
                "header": String(repeating: "h", count: 20),
                "options": [["label": "", "preview": 42], ["label": "B"]],
            ]],
        ]
        ]
        let approval = try JSONDecoder.ccKit().decode(Approval.self, from: JSONSerialization.data(withJSONObject: data))
        let question = try XCTUnwrap(approval.questions?.first)
        XCTAssertEqual(question.header.count, 20)
        XCTAssertEqual(question.options[0].label, "")
        XCTAssertEqual(question.options[0].description, "")
        XCTAssertNil(question.options[0].preview)
        XCTAssertFalse(question.multiSelect)
    }

    func testUnknownApprovalKindIsTolerated() throws {
        let approval = try decodeApproval(kind: "future-question")
        XCTAssertEqual(approval.kind, .unknown("future-question"))
        XCTAssertNil(approval.questions)
    }

    func testAnswerDraftEncodesSingleMultiOtherAndMixedAnswers() throws {
        let questions = try XCTUnwrap(try decodeApproval(kind: "question").questions)
        var draft = QuestionAnswerDraft(questions: questions)
        XCTAssertFalse(draft.isComplete)
        XCTAssertEqual(draft.selectSingleOption("B", at: 0), 1)
        draft.toggleOption("C", at: 1)
        draft.toggleOption("A", at: 1)
        XCTAssertTrue(draft.isComplete)
        XCTAssertEqual(draft.answers, ["Choose one letter.": "B", "Choose letters.": "A, C"])

        var other = QuestionAnswerDraft(questions: [questions[0]])
        XCTAssertTrue(other.setOtherText("  custom answer  ", at: 0))
        XCTAssertEqual(other.answers, ["Choose one letter.": "custom answer"])

        var mixed = QuestionAnswerDraft(questions: [questions[1]])
        mixed.toggleOption("B", at: 0)
        XCTAssertTrue(mixed.setOtherText("custom", at: 0))
        XCTAssertEqual(mixed.answers, ["Choose letters.": "B, custom"])
    }

    func testAnswerDraftRejectsEmptyAndTooLongAndReportsNextQuestion() throws {
        let questions = try XCTUnwrap(try decodeApproval(kind: "question").questions)
        var draft = QuestionAnswerDraft(questions: questions)
        XCTAssertEqual(draft.nextUnansweredQuestionIndex(), 0)
        XCTAssertEqual(draft.selectSingleOption("A", at: 0), 1)
        XCTAssertFalse(draft.isComplete)
        XCTAssertTrue(draft.setOtherText("", at: 1))
        XCTAssertFalse(draft.isComplete)
        XCTAssertFalse(draft.setOtherText(String(repeating: "x", count: 2_001), at: 1))
    }

    @MainActor
    func testQuestionAnswerAndSkipSendExactDecisionBodies() async throws {
        var bodies: [[String: Any]] = []
        QuestionURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/decision") == true,
               let data = QuestionURLProtocol.bodyData(for: request),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                bodies.append(object)
            }
            return QuestionURLProtocol.json(Data("{\"decided\":true,\"sessionId\":\"s\"}".utf8))
        }
        let app = makeApp()
        app.apply(.state(StateSnapshot(sessions: [Session(id: "s", live: true)], entries: ["s": 0])))
        let approval = Approval(requestId: "r", sessionId: "s", kind: .question, toolName: "AskUserQuestion", toolInput: questionInput)
        app.apply(.approval(ApprovalEvent(sessionId: "s", requestId: "r", kind: .question, toolName: "AskUserQuestion", toolInput: questionInput)))
        guard case .success = await app.answerQuestion(approval, answers: ["Choose one letter.": "A", "Choose letters.": "A, B"]) else { return XCTFail("Question answer failed") }
        let skip = Approval(requestId: "skip", sessionId: "s", kind: .question, toolName: "AskUserQuestion", toolInput: questionInput)
        app.apply(.approval(ApprovalEvent(sessionId: "s", requestId: "skip", kind: .question, toolName: "AskUserQuestion", toolInput: questionInput)))
        guard case .success = await app.skipQuestion(skip) else { return XCTFail("Question skip failed") }
        XCTAssertEqual(bodies[0]["behavior"] as? String, "allow")
        XCTAssertEqual(bodies[0]["answers"] as? [String: String], ["Choose one letter.": "A", "Choose letters.": "A, B"])
        XCTAssertEqual(bodies[1]["behavior"] as? String, "deny")
        XCTAssertNil(bodies[1]["answers"])
    }

    @MainActor
    func testQuestionErrorMappingCapabilityAndPresentation() throws {
        let app = makeApp(controllerInfo: ControllerInfo(id: .mac, name: "Mac", kind: .claudeCode, capabilities: [.questions]))
        XCTAssertTrue(app.supportsQuestions)
        XCTAssertEqual(app.actionError(for: APIError.staleResponse(status: 410, message: "late", code: nil)), .alreadyAnswered)
        XCTAssertEqual(app.actionError(for: APIError.staleResponse(status: 409, message: "terminal", code: "answer_in_terminal")), .answerInTerminal)
        XCTAssertEqual(app.actionError(for: APIError.http(status: 400, message: "", code: "answers_required")), .answersRequired)
        XCTAssertEqual(app.actionError(for: APIError.http(status: 400, message: "", code: "answers_invalid")), .answersInvalid)
        XCTAssertEqual(app.actionError(for: APIError.http(status: 400, message: "", code: "answers_keys")), .answersKeys)
        XCTAssertEqual(app.actionError(for: APIError.http(status: 400, message: "", code: "answer_empty")), .answerEmpty)
        XCTAssertEqual(app.actionError(for: APIError.http(status: 400, message: "", code: "answer_too_long")), .answerTooLong)
    }

    func testQuestionCaptionAndTranscriptRowsUseSpikeResultShapes() throws {
        let pending = ToolEntry(tool: "AskUserQuestion", args: questionInput, state: .running)
        XCTAssertEqual(questionTranscriptText(for: pending), "Asking: One; Many")
        let result = "Your questions have been answered: \"Choose one letter.\"=\"A\", \"Choose letters.\"=\"A, B\". You can now continue with these answers in mind."
        let answered = ToolEntry(tool: "AskUserQuestion", args: questionInput, result: result, state: .done)
        XCTAssertEqual(questionTranscriptText(for: answered), "One · A; Many · A, B")
        XCTAssertEqual(questionSheetModel(for: answered)?.questions.map(\.otherText), [nil, nil])
        let declined = ToolEntry(tool: "AskUserQuestion", args: questionInput, result: "The user declined to answer", state: .done)
        XCTAssertEqual(questionTranscriptText(for: declined), "One · Declined; Many · Declined")
        let fallback = ToolEntry(tool: "AskUserQuestion", args: questionInput, result: "unrecognised result", state: .done)
        XCTAssertEqual(questionTranscriptText(for: fallback), "One · Answered; Many · Answered")

        let approval = Approval(requestId: "r", sessionId: "s", kind: .question, toolName: "AskUserQuestion", toolInput: questionInput)
        XCTAssertEqual(approvalCaption(approval), "Asking: One")
        XCTAssertEqual(sessionListCaption(Session(id: "s", pending: [approval])), "Asking: One")
    }

    func testStructuredToolUseResultIsPreferred() {
        let entry = ToolEntry(
            tool: "AskUserQuestion",
            args: questionInput,
            result: "unrecognised",
            toolUseResult: .object(["answers": .object(["Choose one letter.": .string("B"), "Choose letters.": .string("C")])]),
            state: .done
        )
        XCTAssertEqual(questionTranscriptText(for: entry), "One · B; Many · C")
    }

    func testQuestionAnswerDetailPreservesCommaLabels() {
        let question = Question(
            question: "Deploy?",
            header: "Deploy",
            options: [
                QuestionOption(label: "Yes, deploy", description: "Ship it"),
                QuestionOption(label: "No", description: "Do not ship"),
            ],
            multiSelect: true
        )
        let detail = QuestionAnswerDetail(question: question, answer: "Yes, deploy, No, ask later")
        XCTAssertEqual(detail.selectedOptionLabels, ["Yes, deploy", "No"])
        XCTAssertEqual(detail.otherText, "ask later")

        let single = QuestionAnswerDetail(question: question, answer: "Yes, deploy")
        XCTAssertEqual(single.selectedOptionLabels, ["Yes, deploy"])
        XCTAssertNil(single.otherText)
    }

    private func decodeApproval(kind: String) throws -> Approval {
        let data = try JSONSerialization.data(withJSONObject: ["kind": kind, "tool_name": "AskUserQuestion", "tool_input": questionInputJSONObject])
        return try JSONDecoder.ccKit().decode(Approval.self, from: data)
    }

    private var questionInputJSONObject: [String: Any] {
        ["questions": [
            ["question": "Choose one letter.", "header": "One", "options": [["label": "A", "description": "Choose A"], ["label": "B", "description": "Choose B"]], "multiSelect": false],
            ["question": "Choose letters.", "header": "Many", "options": [["label": "A", "description": "Choose A"], ["label": "B", "description": "Choose B"], ["label": "C", "description": "Choose C"]], "multiSelect": true],
        ]]
    }

    private var questionInput: JSONValue {
        .object(["questions": .array([
            .object(["question": .string("Choose one letter."), "header": .string("One"), "options": .array([.object(["label": .string("A"), "description": .string("Choose A")]), .object(["label": .string("B"), "description": .string("Choose B")])]), "multiSelect": .bool(false)]),
            .object(["question": .string("Choose letters."), "header": .string("Many"), "options": .array([.object(["label": .string("A"), "description": .string("Choose A")]), .object(["label": .string("B"), "description": .string("Choose B")]), .object(["label": .string("C"), "description": .string("Choose C")])]), "multiSelect": .bool(true)]),
        ])])
    }

    @MainActor
    private func makeApp(controllerInfo: ControllerInfo? = nil) -> AppStore {
        AppStore(client: APIClient(baseURL: URL(string: "http://localhost:47832")!, session: QuestionURLProtocol.session), bearerProvider: { "token" }, cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), controllerInfo: controllerInfo)
    }
}

private final class QuestionURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QuestionURLProtocol.self]
        return URLSession(configuration: configuration)
    }()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { fatalError("No question URLProtocol handler") }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func bodyData(for request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    static func json(_ body: Data) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: URL(string: "http://localhost")!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, body)
    }
}
