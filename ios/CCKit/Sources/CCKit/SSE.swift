import Foundation

public struct SSEEvent: Sendable, Equatable {
    public var name: String
    public var data: String
    public init(name: String = "message", data: String) { self.name = name; self.data = data }
}

public struct SSEParser: Sendable {
    private var eventName: String?
    private var dataLines: [String] = []

    public init() {}

    public mutating func consume(_ rawLine: String) -> SSEEvent? {
        var line = rawLine
        if line.hasSuffix("\n") { line.removeLast() }
        if line.hasSuffix("\r") { line.removeLast() }
        if line.isEmpty { return dispatch() }
        if line.hasPrefix(":") { return nil }
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(parts[0])
        var value = parts.count == 2 ? String(parts[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        switch field {
        case "event": eventName = value
        case "data": dataLines.append(value)
        default: break
        }
        return nil
    }

    public mutating func finish() -> SSEEvent? { dispatch() }

    private mutating func dispatch() -> SSEEvent? {
        guard !dataLines.isEmpty else { eventName = nil; return nil }
        let event = SSEEvent(name: eventName ?? "message", data: dataLines.joined(separator: "\n"))
        eventName = nil
        dataLines.removeAll(keepingCapacity: true)
        return event
    }
}

public struct TranscriptEvent: Codable, Sendable, Equatable {
    public var sessionId: String?
    public var path: String?
    public var entry: TranscriptEntry?
    public var entryCount: Int?
    public var replace: Bool?
    public var reset: Bool?
    public init(sessionId: String? = nil, path: String? = nil, entry: TranscriptEntry? = nil, entryCount: Int? = nil, replace: Bool? = nil, reset: Bool? = nil) { self.sessionId = sessionId;self.path = path;self.entry = entry;self.entryCount = entryCount;self.replace = replace;self.reset = reset }
}
public struct UsageEvent: Codable, Sendable, Equatable { public var sessionId:String?;public var usage:Usage?;public init(sessionId:String? = nil,usage:Usage? = nil){self.sessionId = sessionId;self.usage = usage} }
public struct SubagentsEvent: Codable, Sendable, Equatable { public var sessionId:String?;public var subagents:[Subagent]?;public init(sessionId:String? = nil,subagents:[Subagent]? = nil){self.sessionId = sessionId;self.subagents = subagents} }
public typealias SubagentEvent = SubagentsEvent
public struct ApprovalEvent: Codable, Sendable, Equatable { public var sessionId:String?;public var requestId:String?;public var kind:ApprovalKind;public var toolName:String?;public var toolInput:JSONValue?;public var toolUseId:String?;public var permissionMode:String?;public var agentType:String?;public var receivedAt:Date?;public var holdLimitMs:Int?;public var mode:ApprovalMode?;public var status:ApprovalStatus?;public var timedOutAt:Date?;public var permissionSuggestions:[JSONValue]?;enum CodingKeys:String,CodingKey{case sessionId,requestId,kind,toolName = "tool_name",toolInput = "tool_input",toolUseId = "tool_use_id",permissionMode = "permission_mode",agentType = "agent_type",receivedAt,holdLimitMs,mode,status,timedOutAt,permissionSuggestions = "permission_suggestions"};public init(sessionId:String? = nil,requestId:String? = nil,kind:ApprovalKind = .generic,toolName:String? = nil,toolInput:JSONValue? = nil,toolUseId:String? = nil,permissionMode:String? = nil,agentType:String? = nil,receivedAt:Date? = nil,holdLimitMs:Int? = nil,mode:ApprovalMode? = nil,status:ApprovalStatus? = nil,timedOutAt:Date? = nil,permissionSuggestions:[JSONValue]? = nil){self.sessionId = sessionId;self.requestId = requestId;self.kind = kind;self.toolName = toolName;self.toolInput = toolInput;self.toolUseId = toolUseId;self.permissionMode = permissionMode;self.agentType = agentType;self.receivedAt = receivedAt;self.holdLimitMs = holdLimitMs;self.mode = mode;self.status = status;self.timedOutAt = timedOutAt;self.permissionSuggestions = permissionSuggestions}
public init(from decoder:Decoder) throws { let c = try decoder.container(keyedBy:CodingKeys.self); self.init(sessionId:try c.decodeIfPresent(String.self,forKey:.sessionId),requestId:try c.decodeIfPresent(String.self,forKey:.requestId),kind:try c.decodeIfPresent(ApprovalKind.self,forKey:.kind) ?? .generic,toolName:try c.decodeIfPresent(String.self,forKey:.toolName),toolInput:try c.decodeIfPresent(JSONValue.self,forKey:.toolInput),toolUseId:try c.decodeIfPresent(String.self,forKey:.toolUseId),permissionMode:try c.decodeIfPresent(String.self,forKey:.permissionMode),agentType:try c.decodeIfPresent(String.self,forKey:.agentType),receivedAt:try c.decodeIfPresent(Date.self,forKey:.receivedAt),holdLimitMs:try c.decodeIfPresent(Int.self,forKey:.holdLimitMs),mode:try c.decodeIfPresent(ApprovalMode.self,forKey:.mode),status:try c.decodeIfPresent(ApprovalStatus.self,forKey:.status),timedOutAt:try c.decodeIfPresent(Date.self,forKey:.timedOutAt),permissionSuggestions:try c.decodeIfPresent([JSONValue].self,forKey:.permissionSuggestions)) } }
public struct DecisionEvent: Codable, Sendable, Equatable { public var sessionId:String?;public var requestId:String?;public var toolName:String?;public var toolInput:JSONValue?;public var permissionMode:String?;public var receivedAt:Date?;public var holdLimitMs:Int?;public var mode:ApprovalMode?;public var status:ApprovalStatus?;public var timedOutAt:Date?;public var behavior:DecisionBehavior?;public var via:String?;public var text:String?;enum CodingKeys:String,CodingKey{case sessionId,requestId,toolName = "tool_name",toolInput = "tool_input",permissionMode = "permission_mode",receivedAt,holdLimitMs,mode,status,timedOutAt,behavior,via,text};public init(sessionId:String? = nil,requestId:String? = nil,toolName:String? = nil,toolInput:JSONValue? = nil,permissionMode:String? = nil,receivedAt:Date? = nil,holdLimitMs:Int? = nil,mode:ApprovalMode? = nil,status:ApprovalStatus? = nil,timedOutAt:Date? = nil,behavior:DecisionBehavior? = nil,via:String? = nil,text:String? = nil){self.sessionId = sessionId;self.requestId = requestId;self.toolName = toolName;self.toolInput = toolInput;self.permissionMode = permissionMode;self.receivedAt = receivedAt;self.holdLimitMs = holdLimitMs;self.mode = mode;self.status = status;self.timedOutAt = timedOutAt;self.behavior = behavior;self.via = via;self.text = text} }
public struct FileEvent: Codable, Sendable, Equatable { public var sessionId:String?;public var name:String?;public var size:Int?;public var mime:String?;public var url:String?;public init(sessionId:String? = nil,name:String? = nil,size:Int? = nil,mime:String? = nil,url:String? = nil){self.sessionId = sessionId;self.name = name;self.size = size;self.mime = mime;self.url = url} }
public struct RegistrySession: Codable, Sendable, Equatable { public var pid:Int?;public var sessionId:String?;public var status:String?;public var name:String?;public var cwd:String?;public var messagingSocketPath:String?;public var transcriptPath:String?;public init(pid:Int? = nil,sessionId:String? = nil,status:String? = nil,name:String? = nil,cwd:String? = nil,messagingSocketPath:String? = nil,transcriptPath:String? = nil){self.pid = pid;self.sessionId = sessionId;self.status = status;self.name = name;self.cwd = cwd;self.messagingSocketPath = messagingSocketPath;self.transcriptPath = transcriptPath} }
public struct RegistryEvent: Codable, Sendable, Equatable { public var sessions:[RegistrySession]?;public init(sessions:[RegistrySession]? = nil){self.sessions = sessions} }

public enum LiveEvent: Sendable, Equatable {
    case connected
    case state(StateSnapshot)
    case stateDelta(StateDelta)
    case transcript(TranscriptEvent)
    case usage(UsageEvent)
    case subagents(SubagentsEvent)
    case subagent(SubagentEvent)
    case approval(ApprovalEvent)
    case decision(DecisionEvent)
    case file(FileEvent)
    case registry(RegistryEvent)
    case sleeping(SleepingEvent)

    public static func decode(name: String, data: String) -> LiveEvent? {
        guard name != "hook" else { return nil }
        guard let bytes = data.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder.ccKit()
        switch name {
        case "state":
            let object = try? decoder.decode([String: JSONValue].self, from: bytes)
            if let object, object["sessionId"] != nil {
                guard var delta = try? decoder.decode(StateDelta.self, from: bytes) else { return nil }
                delta.rawObject = object
                return .stateDelta(delta)
            }
            return try? .state(decoder.decode(StateSnapshot.self, from: bytes))
        case "transcript": return try? .transcript(decoder.decode(TranscriptEvent.self, from: bytes))
        case "usage": return try? .usage(decoder.decode(UsageEvent.self, from: bytes))
        case "subagents": return try? .subagents(decoder.decode(SubagentsEvent.self, from: bytes))
        case "subagent": return try? .subagent(decoder.decode(SubagentEvent.self, from: bytes))
        case "approval": return try? .approval(decoder.decode(ApprovalEvent.self, from: bytes))
        case "decision": return try? .decision(decoder.decode(DecisionEvent.self, from: bytes))
        case "file": return try? .file(decoder.decode(FileEvent.self, from: bytes))
        case "registry": return try? .registry(decoder.decode(RegistryEvent.self, from: bytes))
        case "sleeping": return try? .sleeping(decoder.decode(SleepingEvent.self, from: bytes))
        default: return nil
        }
    }
}

public enum ConnectionStatus: Sendable, Equatable { case connecting, live, reconnecting(attempt: Int), offline }
