import Foundation
import XCTest
@testable import CCKit

@MainActor
final class ActionTests: XCTestCase {
    func testDecisionSuccessSendNowInterruptModeAndUpload() async throws {
        ActionURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/sessions/s/decision": return ActionURLProtocol.json(Data("{\"decided\":true,\"sessionId\":\"s\"}".utf8))
            case "/api/state": return ActionURLProtocol.json(Data("{\"sessions\":[{\"id\":\"s\",\"live\":true,\"state\":\"working\"}],\"entries\":{\"s\":0}}".utf8))
            case "/api/sessions/s/message": return ActionURLProtocol.json(Data("{\"delivered\":true,\"queued\":false,\"route\":\"pane\",\"interrupted\":true}".utf8))
            case "/api/sessions/s/keys": return ActionURLProtocol.json(Data("{\"sent\":true}".utf8))
            case "/api/sessions/s/mode": return ActionURLProtocol.json(Data("{\"mode\":\"remote\"}".utf8))
            case "/api/sessions/s/files": return ActionURLProtocol.json(Data("{\"files\":[{\"name\":\"a.png\",\"size\":3,\"mime\":\"image/png\"}]}".utf8))
            default: return ActionURLProtocol.json(Data("{}".utf8))
            }
        }
        let app = makeApp()
        app.apply(.state(StateSnapshot(sessions: [session()], entries: ["s": 0])))
        let approval = Approval(requestId: "r", sessionId: "s", toolName: "Bash")
        app.apply(.approval(ApprovalEvent(sessionId: "s", requestId: "r", toolName: "Bash")))
        guard case .success = await app.allow(approval, scope: .session) else { return XCTFail("Allow failed") }
        guard case .success = await app.send(text: "run", to: "s", now: true) else { return XCTFail("Send failed") }
        guard case .success = await app.interrupt(sessionID: "s") else { return XCTFail("Interrupt failed") }
        guard case .success = await app.setApprovalMode(sessionID: "s", mode: .remote) else { return XCTFail("Mode failed") }
    }

    func testDecisionFailureRestoresOptimisticApproval() async throws {
        ActionURLProtocol.handler = { _ in ActionURLProtocol.json(500, body: Data("{\"error\":\"boom\"}".utf8)) }
        let app = makeApp()
        app.apply(.state(StateSnapshot(sessions: [session()], entries: ["s": 0])))
        let approval = Approval(requestId: "r", sessionId: "s", toolName: "Bash")
        app.apply(.approval(ApprovalEvent(sessionId: "s", requestId: "r", toolName: "Bash")))
        let result = await app.deny(approval)
        guard case .failure(.server(500, "boom")) = result else { return XCTFail("Expected server failure") }
        XCTAssertEqual(app.approvals(for: "s").map(\.requestId), ["r"])
        XCTAssertTrue(app.deciding.isEmpty)
    }

    func testStaleDecisionAndUnauthorizedAreActionErrors() async throws {
        ActionURLProtocol.handler = { request in
            if request.url?.path == "/api/sessions/s/decision" { return ActionURLProtocol.json(410, body: Data("{\"error\":\"This approval was already answered\"}".utf8)) }
            return ActionURLProtocol.json(Data("{\"sessions\":[],\"entries\":{}}".utf8))
        }
        let app = makeApp()
        app.apply(.state(StateSnapshot(sessions: [session()], entries: ["s": 0])))
        let approval = Approval(requestId: "r", sessionId: "s")
        app.apply(.approval(ApprovalEvent(sessionId: "s", requestId: "r")))
        guard case .failure(.alreadyAnswered) = await app.deny(approval) else { return XCTFail("Expected stale decision") }
        XCTAssertTrue(app.approvals(for: "s").isEmpty, "A stale decision must not leave a dead approval card")

        app.apply(.state(StateSnapshot(sessions: [session()], entries: ["s": 0])))
        app.apply(.approval(ApprovalEvent(sessionId: "s", requestId: "r")))
        ActionURLProtocol.handler = { request in
            if request.url?.path == "/api/sessions/s/decision" { return ActionURLProtocol.json(409, body: Data("{\"error\":\"Waiting in the terminal; this session has no tmux pane to answer from this device\"}".utf8)) }
            return ActionURLProtocol.json(Data("{\"sessions\":[],\"entries\":{}}".utf8))
        }
        guard case .failure(.waitingInTerminal) = await app.allow(approval) else { return XCTFail("Expected terminal waiting error") }

        ActionURLProtocol.handler = { _ in ActionURLProtocol.json(401, body: Data("{\"error\":\"Authentication required\"}".utf8)) }
        guard case .failure(.unauthorized) = await app.send(text: "hello", to: "s") else { return XCTFail("Expected unauthorized") }
    }

    func testCodeFirstMappingWinsAndLegacyMessageFallbackRemains() async throws {
        ActionURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/keys") == true {
                return ActionURLProtocol.json(500, body: Data("{\"error\":\"unrelated text\",\"code\":\"no_pane\"}".utf8))
            }
            return ActionURLProtocol.json(500, body: Data("{\"error\":\"Session has no tmux pane\"}".utf8))
        }
        let app = makeApp()
        guard case .failure(.noPane) = await app.interrupt(sessionID: "s") else { return XCTFail("Expected code-first no-pane mapping") }
        ActionURLProtocol.handler = { _ in ActionURLProtocol.json(500, body: Data("{\"error\":\"Session has no tmux pane\"}".utf8)) }
        guard case .failure(.noPane) = await app.interrupt(sessionID: "s") else { return XCTFail("Expected legacy message fallback") }
    }

    func testNoPaneAndNetworkErrorsAreDistinct() async throws {
        ActionURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/keys") == true { return ActionURLProtocol.json(500, body: Data("{\"error\":\"Session has no tmux pane\"}".utf8)) }
            return ActionURLProtocol.failure(URLError(.notConnectedToInternet))
        }
        let app = makeApp()
        guard case .failure(.noPane) = await app.interrupt(sessionID: "s") else { return XCTFail("Expected no pane") }
        guard case .failure(.network) = await app.send(text: "hello", to: "s") else { return XCTFail("Expected network error") }
    }

    func testQueuedNoteClearsWhenPromptArrives() async throws {
        ActionURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/message") == true { return ActionURLProtocol.json(Data("{\"delivered\":false,\"queued\":true,\"route\":\"pane\"}".utf8)) }
            return ActionURLProtocol.json(Data("{}".utf8))
        }
        let app = makeApp()
        app.apply(.state(StateSnapshot(sessions: [session()], entries: ["s": 0])))
        _ = await app.send(text: "queued work", to: "s")
        XCTAssertEqual(app.queuedNotes(for: "s").count, 1)
        _ = app.openSession("s")
        app.apply(.transcript(TranscriptEvent(sessionId: "s", entry: .prompt(PromptEntry(ts: Date(), text: "queued work now")))) )
        XCTAssertTrue(app.queuedNotes(for: "s").isEmpty)
    }

    func testSentNoteClearsWhenPromptArrives() async throws {
        ActionURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/message") == true { return ActionURLProtocol.json(Data("{\"delivered\":true,\"queued\":false,\"route\":\"socket\"}".utf8)) }
            return ActionURLProtocol.json(Data("{}".utf8))
        }
        let app = makeApp()
        app.apply(.state(StateSnapshot(sessions: [session()], entries: ["s": 0])))
        _ = await app.send(text: "sent now", to: "s")
        XCTAssertEqual(app.queuedNotes(for: "s").map(\.text), ["sent now"])
        _ = app.openSession("s")
        app.apply(.transcript(TranscriptEvent(sessionId: "s", entry: .prompt(PromptEntry(ts: Date(), text: "sent now")))) )
        XCTAssertTrue(app.queuedNotes(for: "s").isEmpty)
    }

    func testLogoutStopsAndClearsState() async throws {
        ActionURLProtocol.handler = { request in
            if request.url?.path == "/api/auth/logout" { return ActionURLProtocol.json(Data("{\"loggedOut\":true}".utf8)) }
            return ActionURLProtocol.json(Data("{}".utf8))
        }
        let app = makeApp()
        app.apply(.state(StateSnapshot(sessions: [session()], entries: ["s": 0])))
        guard case .success = await app.logout() else { return XCTFail("Logout failed") }
        XCTAssertTrue(app.sessions.isEmpty)
        XCTAssertTrue(app.approvals.isEmpty)
        XCTAssertEqual(app.connection, .offline(lastUpdated: nil, error: nil))
    }

    func testComposerAttachmentBecomesAttached() async throws {
        ActionURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/files") == true {
                return ActionURLProtocol.json(Data("{\"files\":[{\"name\":\"a.png\",\"size\":3,\"mime\":\"image/png\"}]}".utf8))
            }
            return ActionURLProtocol.json(Data("{\"delivered\":true,\"queued\":false}".utf8))
        }
        let app = makeApp()
        app.addAttachment(UploadFile(name: "a.png", data: Data([1, 2, 3]), mimeType: "image/png", isImage: true), to: "s")
        for _ in 0..<20 {
            if case .attached = app.attachments(for: "s").first?.state { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Attachment did not finish uploading")
    }

    func testComposerSendIncludesFilesAndUsesSeeAttached() async throws {
        var requestBody = ""
        ActionURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/message") == true {
                requestBody = String(decoding: ActionURLProtocol.bodyData(for: request) ?? Data(), as: UTF8.self)
            }
            return ActionURLProtocol.json(Data("{\"delivered\":true,\"queued\":false}".utf8))
        }
        let app = makeApp()
        guard case .success = await app.send(text: "See attached.", attachments: ["a.txt"], to: "s") else { return XCTFail("Attachment send failed") }
        XCTAssertTrue(requestBody.contains("See attached."))
        XCTAssertTrue(requestBody.contains("a.txt"))
    }

    func testComposerSendBlocksFailedAttachment() async {
        ActionURLProtocol.handler = { _ in ActionURLProtocol.json(500, body: Data("{\"error\":\"upload failed\"}".utf8)) }
        let app = makeApp()
        app.addAttachment(UploadFile(name: "a.txt", data: Data([1]), mimeType: "text/plain"), to: "s")
        for _ in 0..<20 { if case .failed = app.attachments(for: "s").first?.state { break }; try? await Task.sleep(for: .milliseconds(10)) }
        guard case .failure(.invalid("Remove or retry the failed attachment")) = await app.sendComposer(text: "hello", to: "s") else { return XCTFail("Failed attachment did not block send") }
    }

    func testTooLargeAttachmentDoesNotRetryUpload() async throws {
        var uploadCalls = 0
        ActionURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/files") == true { uploadCalls += 1 }
            return ActionURLProtocol.json(Data("{}".utf8))
        }
        let app = makeApp()
        app.addAttachment(
            UploadFile(name: "too-large.bin", data: Data(repeating: 0, count: AttachmentNormalizer.maxFileBytes + 1)),
            to: "s"
        )
        let id = try XCTUnwrap(app.attachments(for: "s").first?.id)
        app.retryAttachment(id: id, sessionID: "s")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(uploadCalls, 0)
        guard case .failed(.tooLarge) = app.attachments(for: "s").first?.state else {
            return XCTFail("Too-large attachment became retryable")
        }
    }

    func testComposerSendWaitsForUploadAndKeepsAttachmentAddedDuringWait() async throws {
        let uploadStarted = expectation(description: "upload started")
        var messageBodies: [String] = []
        await ActionURLProtocol.beginHoldingUploads(uploadStarted: uploadStarted)
        ActionURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/message") == true {
                messageBodies.append(String(decoding: ActionURLProtocol.bodyData(for: request) ?? Data(), as: UTF8.self))
            }
            return ActionURLProtocol.json(Data("{\"files\":[{\"name\":\"a.txt\",\"size\":1}],\"delivered\":true,\"queued\":false}".utf8))
        }
        defer { ActionURLProtocol.stopHoldingUploads() }

        let app = makeApp()
        app.addAttachment(UploadFile(name: "a.txt", data: Data([1]), mimeType: "text/plain"), to: "s")
        let sending = Task { @MainActor in await app.sendComposer(text: "hello", to: "s") }
        await fulfillment(of: [uploadStarted], timeout: 2)
        XCTAssertTrue(messageBodies.isEmpty, "Message request started before upload completed")

        app.addAttachment(UploadFile(name: "later.txt", data: Data([2]), mimeType: "text/plain"), to: "s")
        await ActionURLProtocol.releaseUploads()
        guard case .success = await sending.value else { return XCTFail("Composer send failed") }
        XCTAssertEqual(messageBodies.count, 1)
        XCTAssertTrue(messageBodies[0].contains("a.txt"))
        XCTAssertFalse(messageBodies[0].contains("later.txt"))
        XCTAssertEqual(app.attachments(for: "s").map(\.name), ["later.txt"])
    }

    func testUploadCompletingAfterRemovalDoesNotRestoreTile() async throws {
        let uploadStarted = expectation(description: "upload started")
        await ActionURLProtocol.beginHoldingUploads(uploadStarted: uploadStarted)
        ActionURLProtocol.handler = { _ in ActionURLProtocol.json(Data("{\"files\":[{\"name\":\"removed.txt\",\"size\":1}]}".utf8)) }
        defer { ActionURLProtocol.stopHoldingUploads() }

        let app = makeApp()
        app.addAttachment(UploadFile(name: "removed.txt", data: Data([1]), mimeType: "text/plain"), to: "s")
        await fulfillment(of: [uploadStarted], timeout: 2)
        let id = try XCTUnwrap(app.attachments(for: "s").first?.id)
        app.removeAttachment(id: id, from: "s")
        await ActionURLProtocol.releaseUploads()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(app.attachments(for: "s").isEmpty)
    }

    func testUploadProgressMappingIsBoundedAndDeterminate() {
        XCTAssertEqual(AppStore.uploadProgress(totalBytesSent: 40, totalBytesExpectedToSend: 100), 0.4, accuracy: 0.001)
        XCTAssertEqual(AppStore.uploadProgress(totalBytesSent: 100, totalBytesExpectedToSend: 100), 1)
        XCTAssertEqual(AppStore.uploadProgress(totalBytesSent: 200, totalBytesExpectedToSend: 100), 1)
        XCTAssertEqual(AppStore.uploadProgress(totalBytesSent: 1, totalBytesExpectedToSend: 0), 0)
    }

    private func makeApp(uploadTimeout: TimeInterval = 30) -> AppStore {
        AppStore(serverURL: URL(string: "http://localhost:47832")!, bearerProvider: { "token" }, session: ActionURLProtocol.session, cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), uploadTimeout: uploadTimeout)
    }

    private func session() -> Session { Session(id: "s", name: "Session", live: true, state: .working, usage: Usage()) }
}

private final class ActionURLProtocol: URLProtocol {
    enum Outcome { case response(HTTPURLResponse, Data); case failure(URLError) }

    private final class UncheckedSendableBox<Value>: @unchecked Sendable {
        let value: Value

        init(_ value: Value) {
            self.value = value
        }
    }

    private actor UploadGate {
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private var released = false

        func reset() {
            released = false
        }

        func wait() async {
            if released { return }
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
        }

        func resume() {
            released = true
            continuations.forEach { $0.resume() }
            continuations.removeAll()
        }
    }

    nonisolated(unsafe) static var handler: ((URLRequest) -> Outcome)?
    nonisolated(unsafe) static var holdUploads = false
    nonisolated(unsafe) static var uploadStarted: XCTestExpectation?
    private static let uploadGate = UploadGate()
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ActionURLProtocol.self]
        return URLSession(configuration: configuration)
    }()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if Self.holdUploads, request.url?.path.hasSuffix("/files") == true {
            Self.uploadStarted?.fulfill()
            guard let client else { return }
            let protocolBox = UncheckedSendableBox(self)
            let clientBox = UncheckedSendableBox(client)
            let filename = Self.filename(for: request)
            Task { @MainActor in
                await Self.uploadGate.wait()
                let protocolObject = protocolBox.value
                let client = clientBox.value
                let body = Data("{\"files\":[{\"name\":\"\(filename)\",\"size\":1}]}".utf8)
                guard case .response(let response, let data) = Self.json(body) else { return }
                client.urlProtocol(protocolObject, didReceive: response, cacheStoragePolicy: .notAllowed)
                client.urlProtocol(protocolObject, didLoad: data)
                client.urlProtocolDidFinishLoading(protocolObject)
            }
            return
        }
        guard let outcome = Self.handler?(request) else { fatalError("No action URLProtocol handler") }
        switch outcome {
        case .response(let response, let data):
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error): client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}

    static func beginHoldingUploads(uploadStarted: XCTestExpectation) async {
        await uploadGate.reset()
        holdUploads = true
        Self.uploadStarted = uploadStarted
    }

    static func stopHoldingUploads() {
        holdUploads = false
        uploadStarted = nil
        Task { await uploadGate.resume() }
    }

    static func releaseUploads() async {
        holdUploads = false
        await uploadGate.resume()
    }

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

    private static func filename(for request: URLRequest) -> String {
        let body = String(decoding: bodyData(for: request) ?? Data(), as: UTF8.self)
        let marker = "filename=\""
        guard let start = body.range(of: marker)?.upperBound,
              let end = body[start...].firstIndex(of: "\"") else { return "uploaded.txt" }
        return String(body[start..<end])
    }

    static func json(_ body: Data) -> Outcome { json(200, body: body) }
    static func json(_ status: Int, body: Data) -> Outcome {
        .response(HTTPURLResponse(url: URL(string: "http://localhost")!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, body)
    }
    static func failure(_ error: URLError) -> Outcome { .failure(error) }
}
