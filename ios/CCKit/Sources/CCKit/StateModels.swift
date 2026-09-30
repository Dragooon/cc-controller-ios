import Foundation

public struct Bootstrap: Codable, Sendable, Equatable {
    public var apiVersion: Int?
    public var daemon: DaemonInfo?
    public var capabilities: Capabilities?
    public var limits: Limits?
    public var state: StateSnapshot?

    public init(apiVersion: Int? = nil, daemon: DaemonInfo? = nil, capabilities: Capabilities? = nil, limits: Limits? = nil, state: StateSnapshot? = nil) {
        self.apiVersion = apiVersion
        self.daemon = daemon
        self.capabilities = capabilities
        self.limits = limits
        self.state = state
    }
}

public struct DaemonInfo: Codable, Sendable, Equatable {
    public var version: String?
    public var commit: String?
    public var startedAt: Date?
    public init(version: String? = nil, commit: String? = nil, startedAt: Date? = nil) {
        self.version = version; self.commit = commit; self.startedAt = startedAt
    }
}

public struct Capabilities: Codable, Sendable, Equatable {
    public var bearer: Bool?
    public var pagination: Bool?
    public var gzip: Bool?
    public var sendNow: Bool?
    public var logout: Bool?
    public var values: [String: Bool] { var result: [String: Bool] = [:]; if let bearer { result["bearer"] = bearer }; if let pagination { result["pagination"] = pagination }; if let gzip { result["gzip"] = gzip }; if let sendNow { result["sendNow"] = sendNow }; if let logout { result["logout"] = logout }; return result }
    public init(bearer: Bool? = nil, pagination: Bool? = nil, gzip: Bool? = nil, sendNow: Bool? = nil, logout: Bool? = nil) {
        self.bearer = bearer; self.pagination = pagination; self.gzip = gzip; self.sendNow = sendNow; self.logout = logout
    }
}

public struct Limits: Codable, Sendable, Equatable {
    public var uploadMaxBytes: Int?
    public var jsonMaxBytes: Int?
    public var approvalHoldMs: Int?
    public var sessionTtlHours: Double?
    public init(uploadMaxBytes: Int? = nil, jsonMaxBytes: Int? = nil, approvalHoldMs: Int? = nil, sessionTtlHours: Double? = nil) {
        self.uploadMaxBytes = uploadMaxBytes; self.jsonMaxBytes = jsonMaxBytes; self.approvalHoldMs = approvalHoldMs; self.sessionTtlHours = sessionTtlHours
    }
}

public struct StateSnapshot: Codable, Sendable, Equatable {
    public var sessions: [Session]?
    public var entries: [String: Int]?
    public var device: Device?
    public init(sessions: [Session]? = nil, entries: [String: Int]? = nil, device: Device? = nil) {
        self.sessions = sessions; self.entries = entries; self.device = device
    }
}

public struct StateDelta: Codable, Sendable, Equatable {
    public var sessionId: String?
    public var state: SessionState?
    public var action: String?
    public var startedAt: Date?
    public var idleSince: Date?
    public var lastTool: String?
    public var lastToolInput: JSONValue?
    public var toolRunning: Bool?
    public var lastText: String?
    public var entries: [String: Int]?
    public var usage: Usage?
    public var subagents: [Subagent]?
    public var pending: [Approval]?
    var rawObject: [String: JSONValue] = [:]

    private enum CodingKeys: String, CodingKey {
        case sessionId, state, action, startedAt, idleSince, lastTool, lastToolInput, toolRunning, lastText, entries, usage, subagents, pending
    }

    public init(sessionId: String? = nil, state: SessionState? = nil, action: String? = nil, startedAt: Date? = nil, idleSince: Date? = nil, lastTool: String? = nil, lastToolInput: JSONValue? = nil, toolRunning: Bool? = nil, lastText: String? = nil, entries: [String: Int]? = nil, usage: Usage? = nil, subagents: [Subagent]? = nil, pending: [Approval]? = nil) {
        self.sessionId = sessionId; self.state = state; self.action = action; self.startedAt = startedAt; self.idleSince = idleSince; self.lastTool = lastTool; self.lastToolInput = lastToolInput; self.toolRunning = toolRunning; self.entries = entries; self.usage = usage; self.subagents = subagents; self.pending = pending; self.rawObject = [:]
    }

    public static func == (lhs: StateDelta, rhs: StateDelta) -> Bool {
        lhs.sessionId == rhs.sessionId && lhs.state == rhs.state && lhs.action == rhs.action && lhs.startedAt == rhs.startedAt && lhs.idleSince == rhs.idleSince && lhs.lastTool == rhs.lastTool && lhs.lastToolInput == rhs.lastToolInput && lhs.toolRunning == rhs.toolRunning && lhs.lastText == rhs.lastText && lhs.entries == rhs.entries && lhs.usage == rhs.usage && lhs.subagents == rhs.subagents && lhs.pending == rhs.pending
    }
}

public enum SessionState: Codable, Sendable, Equatable {
    case working, idle, needsYou, ended, unknown(String)
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value { case "working": self = .working; case "idle": self = .idle; case "needs_you": self = .needsYou; case "ended": self = .ended; default: self = .unknown(value) }
    }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
    public var rawValue: String { switch self { case .working: "working"; case .idle: "idle"; case .needsYou: "needs_you"; case .ended: "ended"; case .unknown(let value): value } }
}

public struct Session: Codable, Sendable, Equatable {
    public var id: String?
    public var pid: Int?
    public var name: String?
    public var cwd: String?
    public var project: String?
    public var tmuxPane: String?
    public var tmux: Bool?
    public var location: String?
    public var live: Bool?
    public var state: SessionState?
    public var action: String?
    public var lastTool: String?
    public var lastToolInput: JSONValue?
    public var toolRunning: Bool?
    public var lastText: String?
    public var pending: [Approval]?
    public var usage: Usage?
    public var subagents: [Subagent]?
    public var mode: ApprovalMode?
    public var startedAt: Date?
    public var idleSince: Date?
    public init(id: String? = nil, pid: Int? = nil, name: String? = nil, cwd: String? = nil, project: String? = nil, tmuxPane: String? = nil, tmux: Bool? = nil, location: String? = nil, live: Bool? = nil, state: SessionState? = nil, action: String? = nil, lastTool: String? = nil, lastToolInput: JSONValue? = nil, toolRunning: Bool? = nil, lastText: String? = nil, pending: [Approval]? = nil, usage: Usage? = nil, subagents: [Subagent]? = nil, mode: ApprovalMode? = nil, startedAt: Date? = nil, idleSince: Date? = nil) { self.id = id; self.pid = pid; self.name = name; self.cwd = cwd; self.project = project; self.tmuxPane = tmuxPane; self.tmux = tmux; self.location = location; self.live = live; self.state = state; self.action = action; self.lastTool = lastTool; self.lastToolInput = lastToolInput; self.toolRunning = toolRunning; self.lastText = lastText; self.pending = pending; self.usage = usage; self.subagents = subagents; self.mode = mode; self.startedAt = startedAt; self.idleSince = idleSince }
}

public struct Usage: Codable, Sendable, Equatable {
    public var model: String?
    public var contextTokens: Int?
    public var contextWindow: Int?
    public var contextPercent: Double?
    public var inputTokens: Int?
    public var totalInputTokens: Int?
    public var outputTokens: Int?
    public var outputTokensSnake: Int?
    public var cacheReadTokens: Int?
    public var cacheWriteTokens: Int?
    public var cacheHitRate: Double?
    public var messages: Int?
    private enum CodingKeys: String, CodingKey { case model, contextTokens, contextWindow, contextPercent, inputTokens, totalInputTokens, outputTokens, outputTokensSnake = "output_tokens", cacheReadTokens, cacheWriteTokens, cacheHitRate, messages }
    public init(model: String? = nil, contextTokens: Int? = nil, contextWindow: Int? = nil, contextPercent: Double? = nil, inputTokens: Int? = nil, totalInputTokens: Int? = nil, outputTokens: Int? = nil, outputTokensSnake: Int? = nil, cacheReadTokens: Int? = nil, cacheWriteTokens: Int? = nil, cacheHitRate: Double? = nil, messages: Int? = nil) { self.model = model; self.contextTokens = contextTokens; self.contextWindow = contextWindow; self.contextPercent = contextPercent; self.inputTokens = inputTokens; self.totalInputTokens = totalInputTokens; self.outputTokens = outputTokens; self.outputTokensSnake = outputTokensSnake; self.cacheReadTokens = cacheReadTokens; self.cacheWriteTokens = cacheWriteTokens; self.cacheHitRate = cacheHitRate; self.messages = messages }
}

public enum ApprovalMode: Codable, Sendable, Equatable { case auto, remote, terminal, unknown(String); public init(from d: Decoder) throws { let s = try d.singleValueContainer().decode(String.self); switch s { case "auto":self = .auto; case "remote":self = .remote; case "terminal":self = .terminal; default:self = .unknown(s) } }; public func encode(to e: Encoder) throws { var c = e.singleValueContainer(); try c.encode(rawValue) }; public var rawValue:String { switch self { case .auto:"auto"; case .remote:"remote"; case .terminal:"terminal"; case .unknown(let s):s } } }

public enum ApprovalStatus: Codable, Sendable, Equatable { case remote, terminal, unknown(String); public init(from d: Decoder) throws { let s = try d.singleValueContainer().decode(String.self); switch s { case "remote":self = .remote; case "terminal":self = .terminal; default:self = .unknown(s) } }; public func encode(to e: Encoder) throws { var c = e.singleValueContainer(); try c.encode(rawValue) }; public var rawValue:String { switch self { case .remote:"remote"; case .terminal:"terminal"; case .unknown(let s):s } } }

public struct Subagent: Codable, Sendable, Equatable {
    public var agentId: String?
    public var agent: String?
    public var text: String?
    public var state: SubagentState?
    public var startedAt: Date?
    public var finishedAt: Date?
    public var linked: Bool?
    public var toolUseId: String?
    public var result: String?
    public init(agentId: String? = nil, agent: String? = nil, text: String? = nil, state: SubagentState? = nil, startedAt: Date? = nil, finishedAt: Date? = nil, linked: Bool? = nil, toolUseId: String? = nil, result: String? = nil) { self.agentId = agentId; self.agent = agent; self.text = text; self.state = state; self.startedAt = startedAt; self.finishedAt = finishedAt; self.linked = linked; self.toolUseId = toolUseId; self.result = result }
}

public enum SubagentState: Codable, Sendable, Equatable { case running, done, stopped, failed, unknown(String); public init(from d: Decoder) throws { let s = try d.singleValueContainer().decode(String.self); switch s { case "running":self = .running; case "done":self = .done; case "stopped":self = .stopped; case "failed":self = .failed; default:self = .unknown(s) } }; public func encode(to e: Encoder) throws { var c = e.singleValueContainer(); try c.encode(rawValue) }; public var rawValue:String { switch self { case .running:"running"; case .done:"done"; case .stopped:"stopped"; case .failed:"failed"; case .unknown(let s):s } } }

public struct Approval: Codable, Sendable, Equatable {
    public var requestId: String?
    public var sessionId: String?
    public var toolName: String?
    public var toolInput: JSONValue?
    public var toolUseId: String?
    public var permissionMode: String?
    public var agentType: String?
    public var receivedAt: Date?
    public var holdLimitMs: Int?
    public var mode: ApprovalMode?
    public var status: ApprovalStatus?
    public var timedOutAt: Date?
    public var permissionSuggestions: [JSONValue]?
    public var previousState: SessionState?
    enum CodingKeys: String, CodingKey { case requestId, sessionId, toolName = "tool_name", toolInput = "tool_input", toolUseId = "tool_use_id", permissionMode = "permission_mode", agentType = "agent_type", receivedAt, holdLimitMs, mode, status, timedOutAt, permissionSuggestions = "permission_suggestions", previousState }
    public init(requestId: String? = nil, sessionId: String? = nil, toolName: String? = nil, toolInput: JSONValue? = nil, toolUseId: String? = nil, permissionMode: String? = nil, agentType: String? = nil, receivedAt: Date? = nil, holdLimitMs: Int? = nil, mode: ApprovalMode? = nil, status: ApprovalStatus? = nil, timedOutAt: Date? = nil, permissionSuggestions: [JSONValue]? = nil, previousState: SessionState? = nil) { self.requestId = requestId; self.sessionId = sessionId; self.toolName = toolName; self.toolInput = toolInput; self.toolUseId = toolUseId; self.permissionMode = permissionMode; self.agentType = agentType; self.receivedAt = receivedAt; self.holdLimitMs = holdLimitMs; self.mode = mode; self.status = status; self.timedOutAt = timedOutAt; self.permissionSuggestions = permissionSuggestions; self.previousState = previousState }
}
