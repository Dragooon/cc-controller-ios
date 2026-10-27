import Foundation

public enum APIError: Error, Sendable, Equatable, LocalizedError {
    case unauthorized
    case rateLimited
    case stale
    case staleResponse(status: Int, message: String, code: String?)
    case http(status: Int, message: String, code: String?)
    case transport(URLError)
    case decoding(String)

    public var errorDescription: String? {
        switch self { case .unauthorized: "Unauthorized"; case .rateLimited: "Rate limited"; case .stale: "Stale request"; case .staleResponse(_, let message, _): message; case .http(let status, let message, _): "HTTP \(status): \(message)"; case .transport(let error): error.localizedDescription; case .decoding(let message): message }
    }

    public var daemonMessage: String? {
        switch self {
        case .staleResponse(_, let message, _), .http(_, let message, _): message
        default: nil
        }
    }
}

public actor APIClient {
    public var baseURL: URL { connection.configuredBaseURL }
    public private(set) var bearerToken: String?
    public let authenticationFailures: AsyncStream<Void>
    public nonisolated let connection: ConnectionRouter

    private var authenticationContinuation: AsyncStream<Void>.Continuation
    private var lastCapabilities: Capabilities?

    public init(baseURL: URL, bearerToken: String? = nil, session: URLSession = .shared) {
        self.connection = ConnectionRouter(baseURL: baseURL, session: session)
        self.bearerToken = bearerToken
        var continuation: AsyncStream<Void>.Continuation!
        self.authenticationFailures = AsyncStream { continuation = $0 }
        self.authenticationContinuation = continuation
    }

    public init(connection: ConnectionRouter, bearerToken: String? = nil) {
        self.connection = connection
        self.bearerToken = bearerToken
        var continuation: AsyncStream<Void>.Continuation!
        self.authenticationFailures = AsyncStream { continuation = $0 }
        self.authenticationContinuation = continuation
    }

    public func setBearerToken(_ token: String?) { bearerToken = token }

    public func bootstrap() async throws -> Bootstrap {
        let value: Bootstrap = try await get("/api/bootstrap")
        lastCapabilities = value.capabilities
        return value
    }

    public func state() async throws -> StateSnapshot { try await get("/api/state") }

    public func newSessionOptions() async throws -> NewSessionOptions {
        try await get("/api/sessions/new-options")
    }

    public func createSession(cwd: String, name: String? = nil, model: String? = nil, prompt: String? = nil) async throws -> CreatedSession {
        try await post("/api/sessions", body: CreateSessionRequest(cwd: cwd, name: name, model: model, prompt: prompt))
    }

    /// Stockade: starts a session with an agent instead of in a folder.
    public func createAgentSession(agentId: String, prompt: String) async throws -> CreatedSession {
        try await post("/api/sessions", body: CreateAgentSessionRequest(agentId: agentId, prompt: prompt))
    }

    public func wakeSession(id: String) async throws -> WokenSession {
        try await post("/api/sessions/\(pathComponent(id))/wake", body: EmptyBody())
    }

    public func transcript(sessionID: String, after: Int? = nil, agent: String? = nil) async throws -> [TranscriptEntry] {
        var query: [URLQueryItem] = []
        if let after { query.append(URLQueryItem(name: "after", value: String(after))) }
        if let agent { query.append(URLQueryItem(name: "agent", value: agent)) }
        let response: TranscriptEntriesResponse = try await get(
            "/api/sessions/\(pathComponent(sessionID))/transcript",
            query: query,
            sessionID: sessionID
        )
        return response.entries
    }

    public func agentTranscript(sessionID: String, agentID: String, after: Int? = nil) async throws -> [TranscriptEntry] {
        try await transcript(sessionID: sessionID, after: after, agent: agentID)
    }

    public func transcriptPage(sessionID: String, tail: Int? = nil, before: String? = nil, limit: Int? = nil, agent: String? = nil) async throws -> TranscriptPage {
        var query: [URLQueryItem] = []
        if let tail { query.append(URLQueryItem(name: "tail", value: String(tail))) }
        if let before { query.append(URLQueryItem(name: "before", value: before)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let agent { query.append(URLQueryItem(name: "agent", value: agent)) }
        if lastCapabilities?.pagination != true {
            let entries = try await transcript(sessionID: sessionID, agent: agent)
            return TranscriptPage(entries: entries, total: entries.count, hasMore: false)
        }
        return try await get(
            "/api/sessions/\(pathComponent(sessionID))/transcript",
            query: query,
            sessionID: sessionID
        )
    }

    public func message(
        sessionID: String,
        text: String,
        files: [String] = [],
        now: Bool = false,
        clientMessageId: String? = nil
    ) async throws -> MessageResult {
        let body = MessageRequest(text: text, files: files, now: now, clientMessageId: clientMessageId)
        return try await post(
            "/api/sessions/\(pathComponent(sessionID))/message",
            body: body,
            timeoutInterval: 20
        )
    }

    public func escape(sessionID: String) async throws -> KeyResult { try await post("/api/sessions/\(pathComponent(sessionID))/keys", body: KeyRequest(key: "escape", text: nil)) }
    public func slash(sessionID: String, text: String) async throws -> KeyResult { try await post("/api/sessions/\(pathComponent(sessionID))/keys", body: KeyRequest(key: "slash", text: text)) }
    public func mode(sessionID: String, mode: ApprovalMode) async throws -> ModeResult { try await post("/api/sessions/\(pathComponent(sessionID))/mode", body: ModeRequest(mode: mode.rawValue)) }
    public func decision(sessionID: String, requestID: String, behavior: DecisionBehavior, answers: [String: String]? = nil) async throws -> Decision { try await post("/api/sessions/\(pathComponent(sessionID))/decision", body: DecisionRequest(requestId: requestID, behavior: behavior.rawValue, answers: answers), staleDecision: true) }

    public func peerConversations() async throws -> [PeerConversation] {
        try await get("/api/peer-conversations")
    }

    public func revokePeerConversation(id: String) async throws {
        _ = try await requestData("/api/peer-conversations/\(pathComponent(id))", method: "DELETE")
    }

    public func answerQuestion(sessionID: String, requestID: String, answers: [String: String]) async throws -> Decision {
        try await decision(sessionID: sessionID, requestID: requestID, behavior: .allow, answers: answers)
    }

    public func uploadFile(
        sessionID: String,
        data: Data,
        filename: String,
        mimeType: String? = nil,
        timeout: TimeInterval = 30,
        progress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> UploadedFile {
        let boundary = "CCKit-\(UUID().uuidString)"
        let body = multipartBody(boundary: boundary, filename: filename, mimeType: mimeType ?? "application/octet-stream", data: data)
        let delegate = progress.map(UploadProgressDelegate.init(handler:))
        let response: UploadResponse = try await request(
            "/api/sessions/\(pathComponent(sessionID))/files",
            method: "POST",
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)",
            timeoutInterval: timeout,
            delegate: delegate
        )
        guard let file = response.files?.first else { throw APIError.decoding("Upload response contained no file") }
        return file
    }

    public func downloadFile(sessionID: String, name: String) async throws -> (data: Data, mime: String?) {
        let (data, response) = try await requestData("/api/files/\(pathComponent(sessionID))/\(pathComponent(name))")
        return (data, response.value(forHTTPHeaderField: "Content-Type"))
    }

    public func devices() async throws -> DeviceList { try await get("/api/devices") }
    public func whoAmI() async throws -> WhoAmI { try await get("/api/auth/whoami") }
    public func pairStart(deviceName: String, publicKey: JSONValue? = nil) async throws -> PairStartResponse { try await post("/api/pair/start", body: PairStartRequest(deviceName: deviceName, publicKey: publicKey)) }
    public func pairPoll(code: String) async throws -> PairPollResponse { try await get("/api/pair/poll", query: [URLQueryItem(name: "code", value: code)]) }
    public func nativeEnroll(deviceToken: String, deviceName: String) async throws -> NativeEnrollResponse { try await post("/api/auth/native/enroll", body: NativeEnrollRequest(deviceToken: deviceToken, deviceName: deviceName)) }
    public func nativeLogin(secret: String) async throws -> NativeLoginResponse {
        let response: NativeLoginResponse = try await post("/api/auth/native/login", body: NativeLoginRequest(secret: secret))
        bearerToken = response.token
        return response
    }
    public func logout() async throws -> LogoutResponse {
        let response: LogoutResponse = try await post("/api/auth/logout", body: EmptyBody())
        bearerToken = nil
        return response
    }

    public func eventRequest() async -> URLRequest {
        var query: [URLQueryItem] = []
        if lastCapabilities?.subagentUpsert == true {
            query.append(URLQueryItem(name: "subagentUpsert", value: "true"))
        }
        let target = (try? await connection.target()) ?? ConnectionTarget(baseURL: connection.configuredBaseURL, session: .shared)
        var request = URLRequest(url: endpoint("/api/events", baseURL: target.baseURL, query: query))
        request.httpMethod = "GET"
        applyHeaders(to: &request)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        return request
    }

    public func reportAuthenticationFailure() { authenticationContinuation.yield(()) }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], sessionID: String? = nil) async throws -> T {
        try await request(path, method: "GET", query: query, sessionID: sessionID)
    }

    private func post<T: Encodable, U: Decodable>(
        _ path: String,
        body: T,
        staleDecision: Bool = false,
        timeoutInterval: TimeInterval? = nil
    ) async throws -> U {
        let data: Data
        do { data = try JSONEncoder.ccKit().encode(body) } catch { throw APIError.decoding(error.localizedDescription) }
        return try await request(
            path,
            method: "POST",
            body: data,
            contentType: "application/json",
            staleDecision: staleDecision,
            timeoutInterval: timeoutInterval
        )
    }

    private func request<T: Decodable>(
        _ path: String,
        method: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String? = nil,
        staleDecision: Bool = false,
        timeoutInterval: TimeInterval? = nil,
        delegate: (any URLSessionTaskDelegate)? = nil,
        sessionID: String? = nil
    ) async throws -> T {
        let (data, _) = try await requestData(
            path,
            method: method,
            query: query,
            body: body,
            contentType: contentType,
            staleDecision: staleDecision,
            timeoutInterval: timeoutInterval,
            delegate: delegate
        )
        do {
            let decoder = JSONDecoder.ccKit()
            if let sessionID { decoder.userInfo[.transcriptSessionID] = sessionID }
            let value = try decoder.decode(T.self, from: data)
            #if DEBUG
            if path.contains("/transcript") {
                await TranscriptPerformance.shared.markDecodeDone()
            }
            #endif
            return value
        } catch { throw APIError.decoding(decodingErrorDetail(error)) }
    }

    private func requestData(
        _ path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String? = nil,
        staleDecision: Bool = false,
        timeoutInterval: TimeInterval? = nil,
        delegate: (any URLSessionTaskDelegate)? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let target = try await connection.target()
        var request = URLRequest(url: endpoint(path, baseURL: target.baseURL, query: query))
        request.httpMethod = method
        request.httpBody = body
        if let timeoutInterval { request.timeoutInterval = timeoutInterval }
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        applyHeaders(to: &request)
        do {
            let (data, response): (Data, URLResponse)
            if let delegate, let body {
                (data, response) = try await target.session.upload(for: request, from: body, delegate: delegate)
            } else {
                (data, response) = try await target.session.data(for: request)
            }
            guard let http = response as? HTTPURLResponse else { throw APIError.decoding("Response was not HTTP") }
            guard (200..<300).contains(http.statusCode) else { throw await mappedError(status: http.statusCode, data: data, staleDecision: staleDecision) }
            #if DEBUG
            if path.contains("/transcript") {
                await TranscriptPerformance.shared.markResponseReceived(bytes: data.count)
            }
            #endif
            return (data, http)
        } catch let error as APIError { throw error }
        catch let error as URLError {
            if isNetworkRelayError(error) { connection.invalidate() }
            throw APIError.transport(error)
        }
        catch { throw APIError.decoding(decodingErrorDetail(error)) }
    }

    private func mappedError(status: Int, data: Data, staleDecision: Bool) async -> APIError {
        if status == 401 { authenticationContinuation.yield(()); return .unauthorized }
        if status == 429 { return .rateLimited }
        let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data)
        let message = errorResponse?.error ?? HTTPURLResponse.localizedString(forStatusCode: status)
        let code = errorResponse?.code
        if staleDecision && (status == 409 || status == 410) { return .staleResponse(status: status, message: message, code: code) }
        return .http(status: status, message: message, code: code)
    }

    private func endpoint(_ path: String, baseURL: URL, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [basePath, suffix].filter { !$0.isEmpty }.joined(separator: "/")
        components.queryItems = query.isEmpty ? nil : query
        return components.url!
    }

    private func pathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
    private func applyHeaders(to request: inout URLRequest) {
        if let bearerToken { request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
    }
    private func multipartBody(boundary: String, filename: String, mimeType: String, data: Data) -> Data { var body = Data(); body.append(Data("--\(boundary)\r\n".utf8)); body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename.replacingOccurrences(of: "\"", with: "_"))\"\r\n".utf8)); body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8)); body.append(data); body.append(Data("\r\n--\(boundary)--\r\n".utf8)); return body }
}

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let handler: @Sendable (Int64, Int64) -> Void

    init(handler: @escaping @Sendable (Int64, Int64) -> Void) {
        self.handler = handler
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        handler(totalBytesSent, totalBytesExpectedToSend)
    }
}

private struct TranscriptEntriesResponse: Decodable {
    let entries: [TranscriptEntry]

    init(from decoder: Decoder) throws {
        entries = try decodeTranscriptEntries(from: decoder)
    }
}

private struct EmptyBody: Encodable { }
private struct CreateSessionRequest: Encodable {
    let cwd: String
    let name: String?
    let model: String?
    let prompt: String?

    enum CodingKeys: String, CodingKey { case cwd, name, model, prompt }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cwd, forKey: .cwd)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(prompt, forKey: .prompt)
    }
}
private struct CreateAgentSessionRequest: Encodable {
    let agentId: String
    let prompt: String
}
private struct MessageRequest: Encodable {
    let text: String
    let files: [String]
    let now: Bool
    let clientMessageId: String?

    enum CodingKeys: String, CodingKey { case text, files, now, clientMessageId }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode(files, forKey: .files)
        try container.encode(now, forKey: .now)
        try container.encodeIfPresent(clientMessageId, forKey: .clientMessageId)
    }
}
private struct KeyRequest: Encodable { let key: String; let text: String? }
private struct ModeRequest: Encodable { let mode: String }
private struct DecisionRequest: Encodable {
    let requestId: String
    let behavior: String
    let answers: [String: String]?

    enum CodingKeys: String, CodingKey { case requestId, behavior, answers }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(behavior, forKey: .behavior)
        try container.encodeIfPresent(answers, forKey: .answers)
    }
}
private struct PairStartRequest: Encodable { let deviceName: String; let publicKey: JSONValue? }
private struct NativeEnrollRequest: Encodable { let deviceToken: String; let deviceName: String }
private struct NativeLoginRequest: Encodable { let secret: String }
public struct KeyResult: Codable, Sendable, Equatable { public var sent: Bool?; public init(sent: Bool? = nil) { self.sent = sent } }
public struct ModeResult: Codable, Sendable, Equatable { public var mode: String?; public init(mode: String? = nil) { self.mode = mode } }
