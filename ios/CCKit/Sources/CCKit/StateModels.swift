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
    case archive
    case close
    /// Stockade only: /sudo toggles sudo mode on a writable session.
    case sudo
    /// Lists and revokes owner-approved cross-controller conversations.
    case peerConversations
    /// Stockade: overrides one session's model with POST /api/sessions/:id/model.
    case model
    /// Stockade: reports each session's effort and sets it with POST /api/sessions/:id/effort.
    case effort
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
        case "archive": self = .archive
        case "close": self = .close
        case "sudo": self = .sudo
        case "peer_conversations": self = .peerConversations
        case "model": self = .model
        case "effort": self = .effort
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
        case .archive: "archive"
        case .close: "close"
        case .sudo: "sudo"
        case .peerConversations: "peer_conversations"
        case .model: "model"
        case .effort: "effort"
        case .unknown(let value): value
        }
    }

    public static let all: Set<Self> = [
        .list, .transcript, .send, .decide, .questions, .interrupt, .newSession, .wake, .keys, .mode, .files, .commands, .peerConversations,
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
    public var revs: [String: Int]?
    public var device: Device?
    public var sleeping: [SleepingSession]?
    public init(sessions: [Session]? = nil, entries: [String: Int]? = nil, revs: [String: Int]? = nil, device: Device? = nil, sleeping: [SleepingSession]? = nil) {
        self.sessions = sessions; self.entries = entries; self.revs = revs; self.device = device; self.sleeping = sleeping
    }

    private enum CodingKeys: String, CodingKey { case sessions, entries, revs, device, sleeping }

    /// One row the app can't read is skipped rather than failing the whole state, which would leave the
    /// controller unusable until the server changed.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try container.decodeIfPresent(LossyArray<Session>.self, forKey: .sessions)?.elements
        entries = try? container.decodeIfPresent([String: Int].self, forKey: .entries)
        revs = try? container.decodeIfPresent([String: Int].self, forKey: .revs)
        device = try? container.decodeIfPresent(Device.self, forKey: .device)
        sleeping = try container.decodeIfPresent(LossyArray<SleepingSession>.self, forKey: .sleeping)?.elements
    }
}

/// Decodes an array element by element, dropping the elements that fail.
struct LossyArray<Element: Decodable>: Decodable {
    let elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else if (try? container.decode(JSONValue.self)) == nil {
                // A failed decode doesn't move past the element, so stop rather than loop on it.
                break
            }
        }
        self.elements = elements
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
    /// Stockade: the ids of the effort levels this model takes. Nil when the controller doesn't say.
    public var efforts: [String]?
    /// Stockade: the level this model runs at when a session has none of its own.
    public var defaultEffort: String?

    public init(id: String, label: String, efforts: [String]? = nil, defaultEffort: String? = nil) {
        self.id = id; self.label = label; self.efforts = efforts; self.defaultEffort = defaultEffort
    }
}

public struct NewSessionAgent: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// Stockade: the agent always starts in its own folder, so the app offers no folder choice. Nil on older
    /// controllers, where every agent was fixed.
    public var fixedFolder: Bool?
    /// The model "Default" launches with this agent, and its name. Nil on controllers that don't say.
    public var defaultModel: String?
    public var defaultModelLabel: String?
    /// The level a new session with this agent runs at when none is picked and the model is left on Default.
    public var defaultEffort: String?
    /// The level the agent itself is set to. It applies whichever model is picked. Nil when the agent has none.
    public var effort: String?

    public init(
        id: String,
        name: String,
        fixedFolder: Bool? = nil,
        defaultModel: String? = nil,
        defaultModelLabel: String? = nil,
        defaultEffort: String? = nil,
        effort: String? = nil
    ) {
        self.id = id
        self.name = name
        self.fixedFolder = fixedFolder
        self.defaultModel = defaultModel
        self.defaultModelLabel = defaultModelLabel
        self.defaultEffort = defaultEffort
        self.effort = effort
    }

    /// Whether the new-session sheet offers a folder for this agent.
    public var choosesFolder: Bool { fixedFolder == false }
}

public struct SessionModelResult: Codable, Sendable, Equatable {
    public var model: String
    /// False when the session didn't switch yet.
    public var applied: Bool
    /// When an unapplied switch happens: "next_message" for a live session that restarts on its next message,
    /// nil for a resting one that switches when it next runs.
    public var appliesOn: String?

    public init(model: String, applied: Bool, appliesOn: String? = nil) {
        self.model = model; self.applied = applied; self.appliesOn = appliesOn
    }
}

/// What the app tells the user after the controller accepted a model it hasn't applied yet.
public struct SessionEffortResult: Codable, Sendable, Equatable {
    public var effort: String
    /// False when the session didn't switch yet.
    public var applied: Bool
    /// As for a model: "next_message" for a live session, nil for a resting one that switches when it next runs.
    public var appliesOn: String?

    public init(effort: String, applied: Bool, appliesOn: String? = nil) {
        self.effort = effort; self.applied = applied; self.appliesOn = appliesOn
    }
}

/// How hard a session thinks before it answers: one of the levels the controller offers.
public struct EffortOption: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String

    public init(id: String, label: String) {
        self.id = id; self.label = label
    }
}

/// The id a controller uses for "whatever the model does by default".
public let defaultEffortID = "default"

/// Whether a session has no effort level of its own. A controller says so with no level or with "default".
public func isDefaultEffort(_ effort: String?) -> Bool {
    let id = effort?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return id.isEmpty || id.caseInsensitiveCompare(defaultEffortID) == .orderedSame
}

/// The levels a model takes, in the controller's order. "Default" always stays. Every level is offered when the
/// model is unknown or the controller doesn't list levels by model.
public func effortOptions(_ efforts: [EffortOption], forModel modelID: String?, models: [ModelOption]) -> [EffortOption] {
    guard let modelID,
          let model = models.first(where: { $0.id.caseInsensitiveCompare(modelID) == .orderedSame }),
          let taken = model.efforts else { return efforts }
    let ids = Set(taken.map { $0.lowercased() })
    return efforts.filter { isDefaultEffort($0.id) || ids.contains($0.id.lowercased()) }
}

/// The effort level to show beside a session's model: its own level, else the level its model runs at by
/// default. Nil when neither is known, and then nothing is shown.
public func sessionEffortName(effort: String?, modelID: String?, models: [ModelOption], efforts: [EffortOption]) -> String? {
    if !isDefaultEffort(effort) { return effortLabel(effort, options: efforts) }
    guard let matched = matchingCommandModelID(options: models, usageModel: modelID),
          let model = models.first(where: { $0.id == matched }),
          !isDefaultEffort(model.defaultEffort) else { return nil }
    return effortLabel(model.defaultEffort, options: efforts)
}

/// The model "Default" launches for a new session: the chosen agent's when the controller says, else the
/// controller's own default.
public func newSessionDefaultModelID(options: NewSessionOptions, agent: NewSessionAgent?) -> String {
    if let agentModel = agent?.defaultModel, !agentModel.isEmpty { return agentModel }
    return options.defaultModel
}

/// The name of the model "Default" launches, for the "Default (…)" entry.
public func newSessionDefaultModelLabel(options: NewSessionOptions, agent: NewSessionAgent?) -> String {
    let listedLabel: (String) -> String? = { modelID in
        options.models.first(where: { $0.id.caseInsensitiveCompare(modelID) == .orderedSame })?.label
    }
    if let agentModel = agent?.defaultModel, !agentModel.isEmpty {
        return agent?.defaultModelLabel ?? listedLabel(agentModel) ?? agentModel
    }
    return options.defaultModelLabel ?? listedLabel(options.defaultModel) ?? options.defaultModel
}

/// The level a new session runs at when none is picked. The agent's own level applies whichever model is
/// picked. Without one, a session left on the default model takes the agent's default, and a picked model
/// takes that model's default. Nil when the controller gives none.
public func newSessionDefaultEffortID(options: NewSessionOptions, agent: NewSessionAgent?, pickedModelID: String?) -> String? {
    if let agentLevel = agent?.effort, !isDefaultEffort(agentLevel) { return agentLevel }
    if pickedModelID == nil, let agentDefault = agent?.defaultEffort, !isDefaultEffort(agentDefault) { return agentDefault }
    let modelID = pickedModelID ?? newSessionDefaultModelID(options: options, agent: agent)
    // A short name such as "opus" is listed under exactly that id; a full id may be listed under a variant.
    let exactModel = options.models.first(where: { $0.id.caseInsensitiveCompare(modelID) == .orderedSame })
    let matchedID = matchingCommandModelID(options: options.models, usageModel: modelID)
    let model = exactModel ?? options.models.first(where: { $0.id == matchedID })
    if let model, !isDefaultEffort(model.defaultEffort) {
        return model.defaultEffort
    }
    return nil
}

/// The name shown for an effort level: the controller's label when it offers the level, else the id written
/// as a word. Nil for no level, so nothing is shown.
public func effortLabel(_ effort: String?, options: [EffortOption] = []) -> String? {
    let id = effort?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !id.isEmpty else { return nil }
    if let option = options.first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) {
        return option.label
    }
    switch id.lowercased() {
    case "xhigh": return "Extra"
    default: return id.prefix(1).uppercased() + id.dropFirst().lowercased()
    }
}

/// What the app tells the user after the controller accepted an effort level it hasn't applied yet.
public func effortSwitchPendingText(_ result: SessionEffortResult, label: String? = nil) -> String? {
    guard !result.applied else { return nil }
    let name = label ?? effortLabel(result.effort) ?? result.effort
    return result.appliesOn == "next_message"
        ? "Effort changes to \(name) with your next message"
        : "Effort changes to \(name) when the session next runs"
}

public func modelSwitchPendingText(_ result: SessionModelResult, label: String? = nil) -> String? {
    guard !result.applied else { return nil }
    let name = label ?? result.model
    return result.appliesOn == "next_message"
        ? "Switches to \(name) with your next message"
        : "Switches to \(name) when the session next runs"
}

public struct SessionCommand: Codable, Sendable, Equatable {
    public var name: String
    public var description: String?
    /// Where Claude Code got it: built-in, a skill, a plugin or an MCP server.
    public var source: String?
    public var plugin: String?

    public init(name: String, description: String? = nil, source: String? = nil, plugin: String? = nil) {
        self.name = name; self.description = description; self.source = source; self.plugin = plugin
    }
}

public struct SessionCommandList: Codable, Sendable, Equatable {
    public var commands: [SessionCommand]

    public init(commands: [SessionCommand] = []) { self.commands = commands }
}

public struct ClaudeAgentOption: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var description: String?
    /// The agent selected by Claude Code's `default` entry, when configured.
    public var resolvesTo: String?

    public init(id: String, label: String, description: String? = nil, resolvesTo: String? = nil) {
        self.id = id; self.label = label; self.description = description; self.resolvesTo = resolvesTo
    }
}

public struct NewSessionOptions: Codable, Sendable, Equatable {
    public var folders: [NewSessionFolder]
    public var models: [ModelOption]
    public var defaultModel: String
    /// The name of the model "Default" launches. Nil on controllers that don't say.
    public var defaultModelLabel: String?
    /// Stockade: the effort levels a session can be set to, lowest first. Nil when the controller has none.
    public var efforts: [EffortOption]?
    /// The level a session runs at when none was picked.
    public var defaultEffort: String?
    /// Stockade: the agents a new session can start with. Nil on the Mac, which starts sessions in folders.
    public var agents: [NewSessionAgent]?
    /// Claude Code: the agents a new session can start with. Nil on Stockade.
    public var claudeAgents: [ClaudeAgentOption]?
    /// The first word of the Mac account's full name, when available.
    public var ownerName: String?

    public init(
        folders: [NewSessionFolder] = [],
        models: [ModelOption] = [],
        defaultModel: String = "default",
        agents: [NewSessionAgent]? = nil,
        claudeAgents: [ClaudeAgentOption]? = nil,
        ownerName: String? = nil,
        efforts: [EffortOption]? = nil,
        defaultEffort: String? = nil,
        defaultModelLabel: String? = nil
    ) {
        self.folders = folders
        self.models = models
        self.defaultModel = defaultModel
        self.defaultModelLabel = defaultModelLabel
        self.agents = agents
        self.claudeAgents = claudeAgents
        self.ownerName = ownerName
        self.efforts = efforts
        self.defaultEffort = defaultEffort
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

public struct ArchivedSession: Codable, Sendable, Equatable {
    public var id: String
    public var archivedAt: Date?

    public init(id: String, archivedAt: Date? = nil) {
        self.id = id
        self.archivedAt = archivedAt
    }
}

public struct ClosedSession: Codable, Sendable, Equatable {
    public var id: String
    public var closed: Bool

    public init(id: String, closed: Bool = false) {
        self.id = id
        self.closed = closed
    }
}

public struct SleepingSession: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var shortId: String
    public var name: String?
    public var cwd: String
    public var project: String
    public var lastActiveAt: Date
    public var archivedAt: Date?
    public var lastUserMessageAt: Date?
    /// Stockade: when the person using this app last wrote here. Several people and sessions can write in one
    /// conversation, and only your own messages move it up your list.
    public var lastOwnMessageAt: Date?
    /// Stockade: when the person using this app last did something here other than write: answered an approval or
    /// a question, or stopped the turn.
    public var lastOwnActionAt: Date?
    /// Whether the controller sent `lastOwnMessageAt` at all, even as null. One that doesn't has a single user.
    public var reportsOwnMessageTime = false
    public var lastAssistantMessageAt: Date?

    /// When you last wrote or acted here, for sorting the list. Nil when the controller says you never have.
    public var ownActivityAt: Date? {
        reportsOwnMessageTime ? laterDate(lastOwnMessageAt, lastOwnActionAt) : lastUserMessageAt
    }

    public init(id: String, shortId: String, name: String? = nil, cwd: String, project: String, lastActiveAt: Date, archivedAt: Date? = nil) {
        self.id = id; self.shortId = shortId; self.name = name; self.cwd = cwd; self.project = project; self.lastActiveAt = lastActiveAt; self.archivedAt = archivedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, shortId, name, cwd, project, lastActiveAt, archivedAt, lastUserMessageAt, lastOwnMessageAt, lastOwnActionAt, reportsOwnMessageTime, lastAssistantMessageAt
    }

    /// Only the id is required. A carried-over conversation can come without a folder or an activity time.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        shortId = (try? container.decodeIfPresent(String.self, forKey: .shortId)) ?? String(id.prefix(8))
        name = sessionNameWithoutPreamble(try? container.decodeIfPresent(String.self, forKey: .name))
        cwd = (try? container.decodeIfPresent(String.self, forKey: .cwd)) ?? ""
        let folderName = cwd.split(separator: "/").last.map(String.init) ?? ""
        project = (try? container.decodeIfPresent(String.self, forKey: .project)) ?? folderName
        archivedAt = try? container.decodeIfPresent(Date.self, forKey: .archivedAt)
        lastUserMessageAt = try? container.decodeIfPresent(Date.self, forKey: .lastUserMessageAt)
        // The controller sends the time's key, even as null. The app's own saved copy drops a null, so it says so.
        reportsOwnMessageTime = container.contains(.lastOwnMessageAt)
            || ((try? container.decodeIfPresent(Bool.self, forKey: .reportsOwnMessageTime)) ?? false)
        lastOwnMessageAt = try? container.decodeIfPresent(Date.self, forKey: .lastOwnMessageAt)
        lastOwnActionAt = try? container.decodeIfPresent(Date.self, forKey: .lastOwnActionAt)
        lastAssistantMessageAt = try? container.decodeIfPresent(Date.self, forKey: .lastAssistantMessageAt)
        lastActiveAt = (try? container.decodeIfPresent(Date.self, forKey: .lastActiveAt))
            ?? lastUserMessageAt ?? .distantPast
    }
}

public struct SleepingEvent: Codable, Sendable, Equatable {
    public var sleeping: [SleepingSession]

    public init(sleeping: [SleepingSession] = []) { self.sleeping = sleeping }

    private enum CodingKeys: String, CodingKey { case sleeping }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sleeping = try container.decodeIfPresent(LossyArray<SleepingSession>.self, forKey: .sleeping)?.elements ?? []
    }
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
    public var revs: [String: Int]?
    public var usage: Usage?
    public var subagents: [Subagent]?
    public var shells: [Shell]?
    public var pending: [Approval]?
    var rawObject: [String: JSONValue] = [:]

    private enum CodingKeys: String, CodingKey {
        case sessionId, state, action, startedAt, idleSince, lastTool, lastToolInput, toolRunning, lastText, entries, revs, usage, subagents, shells, pending
    }

    public init(sessionId: String? = nil, state: SessionState? = nil, action: String? = nil, startedAt: Date? = nil, idleSince: Date? = nil, lastTool: String? = nil, lastToolInput: JSONValue? = nil, toolRunning: Bool? = nil, lastText: String? = nil, entries: [String: Int]? = nil, revs: [String: Int]? = nil, usage: Usage? = nil, subagents: [Subagent]? = nil, shells: [Shell]? = nil, pending: [Approval]? = nil) {
        self.sessionId = sessionId; self.state = state; self.action = action; self.startedAt = startedAt; self.idleSince = idleSince; self.lastTool = lastTool; self.toolRunning = toolRunning; self.lastText = lastText; self.entries = entries; self.revs = revs; self.usage = usage; self.subagents = subagents; self.shells = shells; self.pending = pending
        self.rawObject = Self.presentKeys(sessionId: sessionId, state: state, action: action, startedAt: startedAt, idleSince: idleSince, lastTool: lastTool, lastToolInput: lastToolInput, toolRunning: toolRunning, lastText: lastText, entries: entries, revs: revs, usage: usage, subagents: subagents, shells: shells, pending: pending).reduce(into: [:]) { $0[$1] = .null }
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
        if keys.contains("revs") { result.revs = newer.revs }
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
        return Self.presentKeys(sessionId: sessionId, state: state, action: action, startedAt: startedAt, idleSince: idleSince, lastTool: lastTool, lastToolInput: lastToolInput, toolRunning: toolRunning, lastText: lastText, entries: entries, revs: revs, usage: usage, subagents: subagents, shells: shells, pending: pending)
    }

    private static func presentKeys(sessionId: String?, state: SessionState?, action: String?, startedAt: Date?, idleSince: Date?, lastTool: String?, lastToolInput: JSONValue?, toolRunning: Bool?, lastText: String?, entries: [String: Int]?, revs: [String: Int]?, usage: Usage?, subagents: [Subagent]?, shells: [Shell]?, pending: [Approval]?) -> Set<String> {
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
        if revs != nil { keys.insert("revs") }
        if usage != nil { keys.insert("usage") }
        if subagents != nil { keys.insert("subagents") }
        if shells != nil { keys.insert("shells") }
        if pending != nil { keys.insert("pending") }
        return keys
    }

    public static func == (lhs: StateDelta, rhs: StateDelta) -> Bool {
        lhs.sessionId == rhs.sessionId && lhs.state == rhs.state && lhs.action == rhs.action && lhs.startedAt == rhs.startedAt && lhs.idleSince == rhs.idleSince && lhs.lastTool == rhs.lastTool && lhs.lastToolInput == rhs.lastToolInput && lhs.toolRunning == rhs.toolRunning && lhs.lastText == rhs.lastText && lhs.entries == rhs.entries && lhs.revs == rhs.revs && lhs.usage == rhs.usage && lhs.subagents == rhs.subagents && lhs.shells == rhs.shells && lhs.pending == rhs.pending
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
    public var lastUserMessageAt: Date?
    public var lastUserMessageAtExact: Bool?
    /// Stockade: when the person using this app last wrote here. Several people and sessions can write in one
    /// conversation, and only your own messages move it up your list.
    public var lastOwnMessageAt: Date?
    /// Stockade: when the person using this app last did something here other than write: answered an approval or
    /// a question, or stopped the turn.
    public var lastOwnActionAt: Date?
    /// Whether the controller sent `lastOwnMessageAt` at all, even as null. One that doesn't has a single user.
    public var reportsOwnMessageTime = false
    public var lastAssistantMessageAt: Date?
    /// Stockade: the model this session was switched to, when it differs from the default.
    public var model: String?
    /// Stockade: the effort level this session runs at. Nil when the controller can't say.
    public var effort: String?
    public var startedAt: Date?
    public var idleSince: Date?
    public var background: BackgroundSession?
    public var archivedAt: Date?
    public var closable: Bool
    /// Stockade (D3b): where the session started: discord, app, peer or terminal.
    public var origin: String?
    public var startedBy: SessionStarter?
    public var participants: [SessionParticipant]?
    /// Stockade (D3b): false for scopes the app may only read, such as Discord threads.
    public var writable: Bool?
    /// Stockade (D3b): discord, terminal or agent when `writable` is false.
    public var readOnlyReason: String?
    public var sudo: Bool?
    public var agent: SessionAgent?
    /// The `/goal` this session works toward, while one is set.
    public var goal: SessionGoal?

    private enum CodingKeys: String, CodingKey {
        case id, pid, name, cwd, project, tmuxPane, tmux, location, live, state, action, lastTool, lastToolInput, toolRunning, lastText, pending, usage, subagents, shells, mode, commandRoute, lastAssistantMessageAt, lastUserMessageAt, lastUserMessageAtExact, lastOwnMessageAt, lastOwnActionAt, reportsOwnMessageTime, model, effort, startedAt, idleSince, background, archivedAt, closable, origin, startedBy, participants, writable, readOnlyReason, sudo, agent, goal
    }

    public init(id: String? = nil, pid: Int? = nil, name: String? = nil, cwd: String? = nil, project: String? = nil, tmuxPane: String? = nil, tmux: Bool? = nil, location: String? = nil, live: Bool? = nil, state: SessionState? = nil, action: String? = nil, lastTool: String? = nil, lastToolInput: JSONValue? = nil, toolRunning: Bool? = nil, lastText: String? = nil, pending: [Approval]? = nil, usage: Usage? = nil, subagents: [Subagent]? = nil, shells: [Shell]? = nil, mode: ApprovalMode? = nil, commandRoute: String? = nil, lastUserMessageAt: Date? = nil, lastUserMessageAtExact: Bool? = nil, startedAt: Date? = nil, idleSince: Date? = nil, background: BackgroundSession? = nil, archivedAt: Date? = nil, closable: Bool = false, origin: String? = nil, startedBy: SessionStarter? = nil, participants: [SessionParticipant]? = nil, writable: Bool? = nil, readOnlyReason: String? = nil, sudo: Bool? = nil, agent: SessionAgent? = nil) { self.id = id; self.pid = pid; self.name = name; self.cwd = cwd; self.project = project; self.tmuxPane = tmuxPane; self.tmux = tmux; self.location = location; self.live = live; self.state = state; self.action = action; self.lastTool = lastTool; self.lastToolInput = lastToolInput; self.toolRunning = toolRunning; self.lastText = lastText; self.pending = pending; self.usage = usage; self.subagents = subagents; self.shells = shells; self.mode = mode; self.commandRoute = commandRoute; self.lastUserMessageAt = lastUserMessageAt; self.lastUserMessageAtExact = lastUserMessageAtExact; self.startedAt = startedAt; self.idleSince = idleSince; self.background = background; self.archivedAt = archivedAt; self.closable = closable; self.origin = origin; self.startedBy = startedBy; self.participants = participants; self.writable = writable; self.readOnlyReason = readOnlyReason; self.sudo = sudo; self.agent = agent }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id),
            pid: try container.decodeIfPresent(Int.self, forKey: .pid),
            name: sessionNameWithoutPreamble(try container.decodeIfPresent(String.self, forKey: .name)),
            cwd: try container.decodeIfPresent(String.self, forKey: .cwd),
            project: try container.decodeIfPresent(String.self, forKey: .project),
            tmuxPane: try container.decodeIfPresent(String.self, forKey: .tmuxPane),
            tmux: try container.decodeIfPresent(Bool.self, forKey: .tmux),
            location: try container.decodeIfPresent(String.self, forKey: .location),
            live: try container.decodeIfPresent(Bool.self, forKey: .live),
            state: try container.decodeIfPresent(SessionState.self, forKey: .state),
            action: try container.decodeIfPresent(String.self, forKey: .action),
            lastTool: try container.decodeIfPresent(String.self, forKey: .lastTool),
            lastToolInput: try container.decodeIfPresent(JSONValue.self, forKey: .lastToolInput),
            toolRunning: try container.decodeIfPresent(Bool.self, forKey: .toolRunning),
            lastText: try container.decodeIfPresent(String.self, forKey: .lastText),
            pending: try container.decodeIfPresent([Approval].self, forKey: .pending),
            usage: try container.decodeIfPresent(Usage.self, forKey: .usage),
            subagents: try container.decodeIfPresent([Subagent].self, forKey: .subagents),
            shells: try container.decodeIfPresent([Shell].self, forKey: .shells),
            mode: try container.decodeIfPresent(ApprovalMode.self, forKey: .mode),
            commandRoute: try container.decodeIfPresent(String.self, forKey: .commandRoute),
            lastUserMessageAt: try container.decodeIfPresent(Date.self, forKey: .lastUserMessageAt),
            lastUserMessageAtExact: try container.decodeIfPresent(Bool.self, forKey: .lastUserMessageAtExact),
            startedAt: try container.decodeIfPresent(Date.self, forKey: .startedAt),
            idleSince: try container.decodeIfPresent(Date.self, forKey: .idleSince),
            background: try container.decodeIfPresent(BackgroundSession.self, forKey: .background),
            archivedAt: try container.decodeIfPresent(Date.self, forKey: .archivedAt),
            closable: try container.decodeIfPresent(Bool.self, forKey: .closable) ?? false,
            origin: try container.decodeIfPresent(String.self, forKey: .origin),
            startedBy: try container.decodeIfPresent(SessionStarter.self, forKey: .startedBy),
            participants: try container.decodeIfPresent([SessionParticipant].self, forKey: .participants),
            writable: try container.decodeIfPresent(Bool.self, forKey: .writable),
            readOnlyReason: try container.decodeIfPresent(String.self, forKey: .readOnlyReason),
            sudo: try container.decodeIfPresent(Bool.self, forKey: .sudo),
            agent: try container.decodeIfPresent(SessionAgent.self, forKey: .agent)
        )
        lastAssistantMessageAt = try container.decodeIfPresent(Date.self, forKey: .lastAssistantMessageAt)
        // The controller sends the time's key, even as null. The app's own saved copy drops a null, so it says so.
        reportsOwnMessageTime = container.contains(.lastOwnMessageAt)
            || ((try? container.decodeIfPresent(Bool.self, forKey: .reportsOwnMessageTime)) ?? false)
        lastOwnMessageAt = try container.decodeIfPresent(Date.self, forKey: .lastOwnMessageAt)
        lastOwnActionAt = try container.decodeIfPresent(Date.self, forKey: .lastOwnActionAt)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        effort = try container.decodeIfPresent(String.self, forKey: .effort)
        goal = try? container.decodeIfPresent(SessionGoal.self, forKey: .goal)
    }

    /// When you last wrote or acted here, for sorting the list. Nil when the controller says you never have:
    /// someone else's message, or another session's, doesn't count.
    public var ownActivityAt: Date? {
        reportsOwnMessageTime ? laterDate(lastOwnMessageAt, lastOwnActionAt) : lastUserMessageAt
    }
}

/// A session named after its first prompt can carry the tags Stockade puts in front of that prompt
/// ("[sender: shitiz | via: app] Fix the build", or a [peer: …] or [platform: …] tag). The name is shown without them;
/// a name that is only tags is no name.
public func sessionNameWithoutPreamble(_ name: String?) -> String? {
    guard var remaining = name?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
    while remaining.hasPrefix("[sender: ") || remaining.hasPrefix("[platform: ") || remaining.hasPrefix("[peer: ") {
        guard let close = remaining.firstIndex(of: "]") else { break }
        remaining = remaining[remaining.index(after: close)...].trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if remaining.hasPrefix("[/platform]") {
        remaining = String(remaining.dropFirst("[/platform]".count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return remaining.isEmpty ? nil : remaining
}

func laterDate(_ first: Date?, _ second: Date?) -> Date? {
    switch (first, second) {
    case let (first?, second?): return max(first, second)
    case let (first?, nil): return first
    case let (nil, second?): return second
    case (nil, nil): return nil
    }
}

/// Whether `left` should appear before `right` in the Recents list: sessions waiting on you first, then the ones
/// you wrote or acted in most recently.
public func sessionRecencyPrecedes(_ left: Session, _ right: Session) -> Bool {
    let leftNeedsYou = sessionActivity(left) == .needsYou
    let rightNeedsYou = sessionActivity(right) == .needsYou
    if leftNeedsYou != rightNeedsYou { return leftNeedsYou }

    switch (left.ownActivityAt, right.ownActivityAt) {
    case let (leftDate?, rightDate?):
        if leftDate != rightDate { return leftDate > rightDate }
    case (_?, nil): return true
    case (nil, _?): return false
    case (nil, nil): break
    }

    if left.ownActivityAt == nil && right.ownActivityAt == nil {
        let leftActivity = max(left.idleSince ?? .distantPast, left.startedAt ?? .distantPast)
        let rightActivity = max(right.idleSince ?? .distantPast, right.startedAt ?? .distantPast)
        if leftActivity != rightActivity { return leftActivity > rightActivity }
    }

    let leftName = left.name ?? ""
    let rightName = right.name ?? ""
    if leftName != rightName { return leftName.localizedStandardCompare(rightName) == .orderedAscending }
    return (left.id ?? "") < (right.id ?? "")
}

public func sortSessionsForRecents(_ sessions: [Session]) -> [Session] {
    sessions.sorted(by: sessionRecencyPrecedes)
}

public struct SessionStarter: Codable, Sendable, Equatable {
    /// person or agent.
    public var kind: String
    public var name: String
    public init(kind: String, name: String) { self.kind = kind; self.name = name }
}

public struct SessionParticipant: Codable, Sendable, Equatable {
    public var name: String
    public var platform: String?
    public init(name: String, platform: String? = nil) { self.name = name; self.platform = platform }
}

public struct SessionAgent: Codable, Sendable, Equatable {
    public var id: String
    public var name: String?
    public init(id: String, name: String? = nil) { self.id = id; self.name = name }
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
    public var turnOutputTokens: Int?
    public var turnStartedAt: Date?
    public var cacheReadTokens: Int?
    public var cacheWriteTokens: Int?
    public var cacheHitRate: Double?
    public var messages: Int?
    private enum CodingKeys: String, CodingKey { case model, contextTokens, contextWindow, contextPercent, inputTokens, totalInputTokens, outputTokens, outputTokensSnake = "output_tokens", turnOutputTokens, turnStartedAt, cacheReadTokens, cacheWriteTokens, cacheHitRate, messages }
    public init(model: String? = nil, contextTokens: Int? = nil, contextWindow: Int? = nil, contextPercent: Double? = nil, inputTokens: Int? = nil, totalInputTokens: Int? = nil, outputTokens: Int? = nil, outputTokensSnake: Int? = nil, turnOutputTokens: Int? = nil, turnStartedAt: Date? = nil, cacheReadTokens: Int? = nil, cacheWriteTokens: Int? = nil, cacheHitRate: Double? = nil, messages: Int? = nil) { self.model = model; self.contextTokens = contextTokens; self.contextWindow = contextWindow; self.contextPercent = contextPercent; self.inputTokens = inputTokens; self.totalInputTokens = totalInputTokens; self.outputTokens = outputTokens; self.outputTokensSnake = outputTokensSnake; self.turnOutputTokens = turnOutputTokens; self.turnStartedAt = turnStartedAt; self.cacheReadTokens = cacheReadTokens; self.cacheWriteTokens = cacheWriteTokens; self.cacheHitRate = cacheHitRate; self.messages = messages }
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
    /// Stockade (D3b): set on read-only scopes to where the approval must be answered (discord, terminal or agent).
    public var answerIn: String?
    enum CodingKeys: String, CodingKey { case requestId, sessionId, kind, toolName = "tool_name", toolInput = "tool_input", toolUseId = "tool_use_id", permissionMode = "permission_mode", agentType = "agent_type", receivedAt, holdLimitMs, mode, status, timedOutAt, permissionSuggestions = "permission_suggestions", previousState, answerIn }
    public init(requestId: String? = nil, sessionId: String? = nil, kind: ApprovalKind = .generic, toolName: String? = nil, toolInput: JSONValue? = nil, toolUseId: String? = nil, permissionMode: String? = nil, agentType: String? = nil, receivedAt: Date? = nil, holdLimitMs: Int? = nil, mode: ApprovalMode? = nil, status: ApprovalStatus? = nil, timedOutAt: Date? = nil, permissionSuggestions: [JSONValue]? = nil, previousState: SessionState? = nil, answerIn: String? = nil) { self.requestId = requestId; self.sessionId = sessionId; self.kind = kind; self.toolName = toolName; self.toolInput = toolInput; self.toolUseId = toolUseId; self.permissionMode = permissionMode; self.agentType = agentType; self.receivedAt = receivedAt; self.holdLimitMs = holdLimitMs; self.mode = mode; self.status = status; self.timedOutAt = timedOutAt; self.permissionSuggestions = permissionSuggestions; self.previousState = previousState; self.answerIn = answerIn }

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
            previousState: try container.decodeIfPresent(SessionState.self, forKey: .previousState),
            answerIn: try container.decodeIfPresent(String.self, forKey: .answerIn)
        )
    }
}
