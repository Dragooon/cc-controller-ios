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
        let upload = await app.upload([UploadFile(name: "a.png", data: Data([1, 2, 3]), mimeType: "image/png")], to: "s")
        XCTAssertEqual(upload, .success([UploadedFile(name: "a.png", size: 3, mime: "image/png")]))
        XCTAssertEqual(app.uploads["a.png"]?.state, .succeeded)
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
        app.apply(.transcript(TranscriptEvent(sessionId: "s", entry: .prompt(PromptEntry(text: "queued work now")))) )
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

    func testUploadTooLargeServerNetworkAndTimeoutAlwaysFinish() async throws {
        let tooLarge = UploadFile(name: "large.bin", data: Data(repeating: 0, count: 25 * 1024 * 1024 + 1))
        let app = makeApp(uploadTimeout: 0.01)
        let tooLargeResult = await app.upload([tooLarge], to: "s")
        guard case .failure(.tooLarge) = tooLargeResult else { return XCTFail("Expected size failure") }
        guard case .failed(.tooLarge) = app.uploads["large.bin"]?.state else { return XCTFail("Expected terminal size progress") }

        ActionURLProtocol.handler = { _ in ActionURLProtocol.json(413, body: Data("{\"error\":\"Upload exceeds 25 MB per file\"}".utf8)) }
        let serverResult = await app.upload([UploadFile(name: "server.bin", data: Data([1]))], to: "s")
        guard case .failure(.tooLarge) = serverResult else { return XCTFail("Expected server size failure") }
        guard case .failed(.tooLarge) = app.uploads["server.bin"]?.state else { return XCTFail("Expected terminal server progress") }

        ActionURLProtocol.handler = { _ in ActionURLProtocol.failure(URLError(.notConnectedToInternet)) }
        let networkResult = await app.upload([UploadFile(name: "network.bin", data: Data([1]))], to: "s")
        guard case .failure(.network) = networkResult else { return XCTFail("Expected network failure") }
        guard case .failed(.network) = app.uploads["network.bin"]?.state else { return XCTFail("Expected terminal network progress") }

        ActionURLProtocol.handler = { request in
            XCTAssertLessThanOrEqual(request.timeoutInterval, 0.01)
            return ActionURLProtocol.failure(URLError(.timedOut))
        }
        let timeoutResult = await app.upload([UploadFile(name: "timeout.bin", data: Data([1]))], to: "s")
        guard case .failure(.timeout) = timeoutResult else { return XCTFail("Expected timeout failure") }
        guard case .failed(.timeout) = app.uploads["timeout.bin"]?.state else { return XCTFail("Expected terminal timeout progress") }
    }

    private func makeApp(uploadTimeout: TimeInterval = 30) -> AppStore {
        AppStore(serverURL: URL(string: "http://localhost:47832")!, bearerProvider: { "token" }, session: ActionURLProtocol.session, cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), uploadTimeout: uploadTimeout)
    }

    private func session() -> Session { Session(id: "s", name: "Session", live: true, state: .working, usage: Usage()) }
}

private final class ActionURLProtocol: URLProtocol {
    enum Outcome { case response(HTTPURLResponse, Data); case failure(URLError) }
    nonisolated(unsafe) static var handler: ((URLRequest) -> Outcome)?
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ActionURLProtocol.self]
        return URLSession(configuration: configuration)
    }()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
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

    static func json(_ body: Data) -> Outcome { json(200, body: body) }
    static func json(_ status: Int, body: Data) -> Outcome {
        .response(HTTPURLResponse(url: URL(string: "http://localhost")!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, body)
    }
    static func failure(_ error: URLError) -> Outcome { .failure(error) }
}
