import Foundation

public enum ControllerKind: Codable, Sendable, Equatable {
    case claudeCode
    case stockade
    case unknown(String)

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "claude-code": self = .claudeCode
        case "stockade": self = .stockade
        default: self = .unknown(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var rawValue: String {
        switch self {
        case .claudeCode: "claude-code"
        case .stockade: "stockade"
        case .unknown(let value): value
        }
    }
}

public enum ControllerCapability: RawRepresentable, Hashable, Codable, Sendable {
    case list
    case transcript
    case send
    case decide
    case questions
    case interrupt
    case newSession
    case wake
    case keys
    case mode
    case files
    case commands
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "list": self = .list
        case "transcript": self = .transcript
        case "send": self = .send
        case "decide": self = .decide
        case "questions": self = .questions
        case "interrupt": self = .interrupt
        case "new_session": self = .newSession
        case "wake": self = .wake
        case "keys": self = .keys
        case "mode": self = .mode
        case "files": self = .files
        case "commands": self = .commands
        default: self = .unknown(rawValue)
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var rawValue: String {
        switch self {
        case .list: "list"
        case .transcript: "transcript"
        case .send: "send"
        case .decide: "decide"
        case .questions: "questions"
        case .interrupt: "interrupt"
        case .newSession: "new_session"
        case .wake: "wake"
        case .keys: "keys"
        case .mode: "mode"
        case .files: "files"
        case .commands: "commands"
        case .unknown(let value): value
        }
    }

    public static let all: Set<Self> = [
        .list, .transcript, .send, .decide, .questions, .interrupt, .newSession, .wake, .keys, .mode, .files, .commands,
    ]
}

public struct ControllerInfo: Codable, Sendable, Equatable {
    public let id: ControllerID
    public let name: String
    public let kind: ControllerKind
    public let capabilities: Set<ControllerCapability>

    public init(id: ControllerID, name: String, kind: ControllerKind, capabilities: Set<ControllerCapability>) {
        self.id = id
        self.name = name
        self.kind = kind
        self.capabilities = capabilities
    }
}

public struct Bootstrap: Codable, Sendable, Equatable {
    public var controller: ControllerInfo?
    public var apiVersion: Int?
    public var daemon: DaemonInfo?
    public var capabilities: Capabilities?
    public var limits: Limits?
    public var state: StateSnapshot?

    public init(controller: ControllerInfo? = nil, apiVersion: Int? = nil, daemon: DaemonInfo? = nil, capabilities: Capabilities? = nil, limits: Limits? = nil, state: StateSnapshot? = nil) {
        self.controller = controller
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
    public var errorCodes: Bool?
    public var subagentUpsert: Bool?
    public var values: [String: Bool] { var result: [String: Bool] = [:]; if let bearer { result["bearer"] = bearer }; if let pagination { result["pagination"] = pagination }; if let gzip { result["gzip"] = gzip }; if let sendNow { result["sendNow"] = sendNow }; if let logout { result["logout"] = logout }; if let errorCodes { result["errorCodes"] = errorCodes }; if let subagentUpsert { result["subagentUpsert"] = subagentUpsert }; return result }
    public init(bearer: Bool? = nil, pagination: Bool? = nil, gzip: Bool? = nil, sendNow: Bool? = nil, logout: Bool? = nil, errorCodes: Bool? = nil, subagentUpsert: Bool? = nil) {
        self.bearer = bearer; self.pagination = pagination; self.gzip = gzip; self.sendNow = sendNow; self.logout = logout; self.errorCodes = errorCodes; self.subagentUpsert = subagentUpsert
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
    public var sleeping: [SleepingSession]?
    public init(sessions: [Session]? = nil, entries: [String: Int]? = nil, device: Device? = nil, sleeping: [SleepingSession]? = nil) {
        self.sessions = sessions; self.entries = entries; self.device = device; self.sleeping = sleeping
    }
}

public struct NewSessionFolder: Codable, Sendable, Equatable, Identifiable {
    public var path: String
    public var name: String
    public var lastUsedAt: Date?
    public var id: String { path }

    public init(path: String, name: String, lastUsedAt: Date? = nil) {
        self.path = path; self.name = name; self.lastUsedAt = lastUsedAt
    }
}

public struct ModelOption: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String

    public init(id: String, label: String) {
        self.id = id; self.label = label
    }
}

public struct NewSessionOptions: Codable, Sendable, Equatable {
    public var folders: [NewSessionFolder]
    public var models: [ModelOption]
    public var defaultModel: String

    public init(folders: [NewSessionFolder] = [], models: [ModelOption] = [], defaultModel: String = "default") {
        self.folders = folders; self.models = models; self.defaultModel = defaultModel
    }
}

public struct CreatedSession: Codable, Sendable, Equatable {
    public var id: String
    public var shortId: String
    public var name: String?

    public init(id: String, shortId: String, name: String? = nil) {
        self.id = id; self.shortId = shortId; self.name = name
    }
}

public struct WokenSession: Codable, Sendable, Equatable {
    public var id: String

    public init(id: String) { self.id = id }
}

public struct SleepingSession: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var shortId: String
    public var name: String?
    public var cwd: String
    public var project: String
    public var lastActiveAt: Date

    public init(id: String, shortId: String, name: String? = nil, cwd: String, project: String, lastActiveAt: Date) {
        self.id = id; self.shortId = shortId; self.name = name; self.cwd = cwd; self.project = project; self.lastActiveAt = lastActiveAt
    }
}

public struct SleepingEvent: Codable, Sendable, Equatable {
    public var sleeping: [SleepingSession]

    public init(sleeping: [SleepingSession] = []) { self.sleeping = sleeping }
}

public struct BackgroundSession: Codable, Sendable, Equatable {
    public var shortId: String

    public init(shortId: String) { self.shortId = shortId }
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
    public var shells: [Shell]?
    public var pending: [Approval]?
    var rawObject: [String: JSONValue] = [:]

    private enum CodingKeys: String, CodingKey {
        case sessionId, state, action, startedAt, idleSince, lastTool, lastToolInput, toolRunning, lastText, entries, usage, subagents, shells, pending
    }

    public init(sessionId: String? = nil, state: SessionState? = nil, action: String? = nil, startedAt: Date? = nil, idleSince: Date? = nil, lastTool: String? = nil, lastToolInput: JSONValue? = nil, toolRunning: Bool? = nil, lastText: String? = nil, entries: [String: Int]? = nil, usage: Usage? = nil, subagents: [Subagent]? = nil, shells: [Shell]? = nil, pending: [Approval]? = nil) {
        self.sessionId = sessionId; self.state = state; self.action = action; self.startedAt = startedAt; self.idleSince = idleSince; self.lastTool = lastTool; self.lastToolInput = lastToolInput; self.toolRunning = toolRunning; self.lastText = lastText; self.entries = entries; self.usage = usage; self.subagents = subagents; self.shells = shells; self.pending = pending
        self.rawObject = Self.presentKeys(sessionId: sessionId, state: state, action: action, startedAt: startedAt, idleSince: idleSince, lastTool: lastTool, lastToolInput: lastToolInput, toolRunning: toolRunning, lastText: lastText, entries: entries, usage: usage, subagents: subagents, shells: shells, pending: pending).reduce(into: [:]) { $0[$1] = .null }
    }

    func merged(with newer: StateDelta) -> StateDelta {
        var result = self
        let keys = newer.presentKeys
        if keys.contains("sessionId") { result.sessionId = newer.sessionId }
        if keys.contains("state") { result.state = newer.state }
        if keys.contains("action") { result.action = newer.action }
        if keys.contains("startedAt") { result.startedAt = newer.startedAt }
        if keys.contains("idleSince") { result.idleSince = newer.idleSince }
        if keys.contains("lastTool") { result.lastTool = newer.lastTool }
        if keys.contains("lastToolInput") { result.lastToolInput = newer.lastToolInput }
        if keys.contains("toolRunning") { result.toolRunning = newer.toolRunning }
        if keys.contains("lastText") { result.lastText = newer.lastText }
        if keys.contains("entries") { result.entries = newer.entries }
        if keys.contains("usage") { result.usage = newer.usage }
        if keys.contains("subagents") { result.subagents = newer.subagents }
        if keys.contains("shells") { result.shells = newer.shells }
        if keys.contains("pending") { result.pending = newer.pending }
        result.rawObject = rawObject
        for key in keys { result.rawObject[key] = newer.rawObject[key] ?? .null }
        return result
    }

    private var presentKeys: Set<String> {
        if !rawObject.isEmpty { return Set(rawObject.keys) }
        return Self.presentKeys(sessionId: sessionId, state: state, action: action, startedAt: startedAt, idleSince: idleSince, lastTool: lastTool, lastToolInput: lastToolInput, toolRunning: toolRunning, lastText: lastText, entries: entries, usage: usage, subagents: subagents, shells: shells, pending: pending)
    }

    private static func presentKeys(sessionId: String?, state: SessionState?, action: String?, startedAt: Date?, idleSince: Date?, lastTool: String?, lastToolInput: JSONValue?, toolRunning: Bool?, lastText: String?, entries: [String: Int]?, usage: Usage?, subagents: [Subagent]?, shells: [Shell]?, pending: [Approval]?) -> Set<String> {
        var keys = Set<String>()
        if sessionId != nil { keys.insert("sessionId") }
        if state != nil { keys.insert("state") }
        if action != nil { keys.insert("action") }
        if startedAt != nil { keys.insert("startedAt") }
        if idleSince != nil { keys.insert("idleSince") }
        if lastTool != nil { keys.insert("lastTool") }
        if lastToolInput != nil { keys.insert("lastToolInput") }
        if toolRunning != nil { keys.insert("toolRunning") }
        if lastText != nil { keys.insert("lastText") }
        if entries != nil { keys.insert("entries") }
        if usage != nil { keys.insert("usage") }
        if subagents != nil { keys.insert("subagents") }
        if shells != nil { keys.insert("shells") }
        if pending != nil { keys.insert("pending") }
        return keys
    }

    public static func == (lhs: StateDelta, rhs: StateDelta) -> Bool {
        lhs.sessionId == rhs.sessionId && lhs.state == rhs.state && lhs.action == rhs.action && lhs.startedAt == rhs.startedAt && lhs.idleSince == rhs.idleSince && lhs.lastTool == rhs.lastTool && lhs.lastToolInput == rhs.lastToolInput && lhs.toolRunning == rhs.toolRunning && lhs.lastText == rhs.lastText && lhs.entries == rhs.entries && lhs.usage == rhs.usage && lhs.subagents == rhs.subagents && lhs.shells == rhs.shells && lhs.pending == rhs.pending
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
    public var shells: [Shell]?
    public var mode: ApprovalMode?
    public var commandRoute: String?
    public var startedAt: Date?
    public var idleSince: Date?
    public var background: BackgroundSession?
    public init(id: String? = nil, pid: Int? = nil, name: String? = nil, cwd: String? = nil, project: String? = nil, tmuxPane: String? = nil, tmux: Bool? = nil, location: String? = nil, live: Bool? = nil, state: SessionState? = nil, action: String? = nil, lastTool: String? = nil, lastToolInput: JSONValue? = nil, toolRunning: Bool? = nil, lastText: String? = nil, pending: [Approval]? = nil, usage: Usage? = nil, subagents: [Subagent]? = nil, shells: [Shell]? = nil, mode: ApprovalMode? = nil, commandRoute: String? = nil, startedAt: Date? = nil, idleSince: Date? = nil, background: BackgroundSession? = nil) { self.id = id; self.pid = pid; self.name = name; self.cwd = cwd; self.project = project; self.tmuxPane = tmuxPane; self.tmux = tmux; self.location = location; self.live = live; self.state = state; self.action = action; self.lastTool = lastTool; self.lastToolInput = lastToolInput; self.toolRunning = toolRunning; self.lastText = lastText; self.pending = pending; self.usage = usage; self.subagents = subagents; self.shells = shells; self.mode = mode; self.commandRoute = commandRoute; self.startedAt = startedAt; self.idleSince = idleSince; self.background = background }
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
    public var background: Bool?
    public init(agentId: String? = nil, agent: String? = nil, text: String? = nil, state: SubagentState? = nil, startedAt: Date? = nil, finishedAt: Date? = nil, linked: Bool? = nil, toolUseId: String? = nil, result: String? = nil, background: Bool? = nil) { self.agentId = agentId; self.agent = agent; self.text = text; self.state = state; self.startedAt = startedAt; self.finishedAt = finishedAt; self.linked = linked; self.toolUseId = toolUseId; self.result = result; self.background = background }
}

public enum SubagentState: Codable, Sendable, Equatable { case running, done, stopped, failed, unknown(String); public init(from d: Decoder) throws { let s = try d.singleValueContainer().decode(String.self); switch s { case "running":self = .running; case "done":self = .done; case "stopped":self = .stopped; case "failed":self = .failed; default:self = .unknown(s) } }; public func encode(to e: Encoder) throws { var c = e.singleValueContainer(); try c.encode(rawValue) }; public var rawValue:String { switch self { case .running:"running"; case .done:"done"; case .stopped:"stopped"; case .failed:"failed"; case .unknown(let s):s } } }

public enum ShellState: Codable, Sendable, Equatable { case running, done, stopped, failed, unknown(String); public init(from d: Decoder) throws { let s = try d.singleValueContainer().decode(String.self); switch s { case "running":self = .running; case "done":self = .done; case "stopped":self = .stopped; case "failed":self = .failed; default:self = .unknown(s) } }; public func encode(to e: Encoder) throws { var c = e.singleValueContainer(); try c.encode(rawValue) }; public var rawValue:String { switch self { case .running:"running"; case .done:"done"; case .stopped:"stopped"; case .failed:"failed"; case .unknown(let s):s } } }

public struct Shell: Codable, Sendable, Equatable {
    public var toolUseId: String?
    public var taskId: String?
    public var description: String?
    public var command: String?
    public var state: ShellState?
    public var startedAt: Date?
    public var finishedAt: Date?
    public init(toolUseId: String? = nil, taskId: String? = nil, description: String? = nil, command: String? = nil, state: ShellState? = nil, startedAt: Date? = nil, finishedAt: Date? = nil) {
        self.toolUseId = toolUseId; self.taskId = taskId; self.description = description; self.command = command; self.state = state; self.startedAt = startedAt; self.finishedAt = finishedAt
    }
}

public struct Approval: Codable, Sendable, Equatable {
    public var requestId: String?
    public var sessionId: String?
    public var kind: ApprovalKind
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
    enum CodingKeys: String, CodingKey { case requestId, sessionId, kind, toolName = "tool_name", toolInput = "tool_input", toolUseId = "tool_use_id", permissionMode = "permission_mode", agentType = "agent_type", receivedAt, holdLimitMs, mode, status, timedOutAt, permissionSuggestions = "permission_suggestions", previousState }
    public init(requestId: String? = nil, sessionId: String? = nil, kind: ApprovalKind = .generic, toolName: String? = nil, toolInput: JSONValue? = nil, toolUseId: String? = nil, permissionMode: String? = nil, agentType: String? = nil, receivedAt: Date? = nil, holdLimitMs: Int? = nil, mode: ApprovalMode? = nil, status: ApprovalStatus? = nil, timedOutAt: Date? = nil, permissionSuggestions: [JSONValue]? = nil, previousState: SessionState? = nil) { self.requestId = requestId; self.sessionId = sessionId; self.kind = kind; self.toolName = toolName; self.toolInput = toolInput; self.toolUseId = toolUseId; self.permissionMode = permissionMode; self.agentType = agentType; self.receivedAt = receivedAt; self.holdLimitMs = holdLimitMs; self.mode = mode; self.status = status; self.timedOutAt = timedOutAt; self.permissionSuggestions = permissionSuggestions; self.previousState = previousState }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            requestId: try container.decodeIfPresent(String.self, forKey: .requestId),
            sessionId: try container.decodeIfPresent(String.self, forKey: .sessionId),
            kind: try container.decodeIfPresent(ApprovalKind.self, forKey: .kind) ?? .generic,
            toolName: try container.decodeIfPresent(String.self, forKey: .toolName),
            toolInput: try container.decodeIfPresent(JSONValue.self, forKey: .toolInput),
            toolUseId: try container.decodeIfPresent(String.self, forKey: .toolUseId),
            permissionMode: try container.decodeIfPresent(String.self, forKey: .permissionMode),
            agentType: try container.decodeIfPresent(String.self, forKey: .agentType),
            receivedAt: try container.decodeIfPresent(Date.self, forKey: .receivedAt),
            holdLimitMs: try container.decodeIfPresent(Int.self, forKey: .holdLimitMs),
            mode: try container.decodeIfPresent(ApprovalMode.self, forKey: .mode),
            status: try container.decodeIfPresent(ApprovalStatus.self, forKey: .status),
            timedOutAt: try container.decodeIfPresent(Date.self, forKey: .timedOutAt),
            permissionSuggestions: try container.decodeIfPresent([JSONValue].self, forKey: .permissionSuggestions),
            previousState: try container.decodeIfPresent(SessionState.self, forKey: .previousState)
        )
    }
}
