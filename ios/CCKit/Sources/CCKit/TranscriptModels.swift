import Foundation

public struct Paste: Codable, Sendable, Equatable { public var lines: Int?; public var text: String?; public init(lines: Int? = nil, text: String? = nil) { self.lines = lines; self.text = text } }

public struct PromptEntry: Codable, Sendable, Equatable {
    public var id: String?; public var rev: Int?; public var ts: Date?; public var origin: String?; public var from: String?; public var text: String?; public var command: String?; public var paste: Paste?; public var queued: Bool?; public var forceSent: Bool?; public var attachments: [String]?
    public init(id: String? = nil, rev: Int? = nil, ts: Date? = nil, origin: String? = nil, from: String? = nil, text: String? = nil, command: String? = nil, paste: Paste? = nil, queued: Bool? = nil, forceSent: Bool? = nil, attachments: [String]? = nil) { self.id = id;self.rev = rev;self.ts = ts;self.origin = origin;self.from = from;self.text = text;self.command = command;self.paste = paste;self.queued = queued;self.forceSent = forceSent;self.attachments = attachments }
}
public struct AssistantEntry: Codable, Sendable, Equatable {
    public var id: String?
    public var rev: Int?
    public var ts: Date?
    public var text: String?
    public var model: String?
    public var usage: Usage?
    public var outputTokensSnake: Int?
    private enum CodingKeys: String, CodingKey { case id, rev, ts, text, model, usage, outputTokensSnake = "output_tokens" }
    public init(id: String? = nil, rev: Int? = nil, ts: Date? = nil, text: String? = nil, model: String? = nil, usage: Usage? = nil, outputTokensSnake: Int? = nil) {
        self.id = id; self.rev = rev; self.ts = ts; self.text = text; self.model = model; self.usage = usage; self.outputTokensSnake = outputTokensSnake
    }
}
public enum ToolState: Codable, Sendable, Equatable { case running, done, unknown(String); public init(from d:Decoder)throws{let s = try d.singleValueContainer().decode(String.self);switch s{case "running":self = .running;case "done":self = .done;default:self = .unknown(s)}};public func encode(to e:Encoder)throws{var c = e.singleValueContainer();try c.encode(rawValue)};public var rawValue:String{switch self{case .running:"running";case .done:"done";case .unknown(let s):s}} }
public struct ToolEntry: Codable, Sendable, Equatable { public var id:String?;public var rev:Int?;public var ts:Date?;public var toolUseId:String?;public var tool:String?;public var args:JSONValue?;public var text:String?;public var result:String?;public var state:ToolState?;public var durationMs:Int?; public init(id:String? = nil,rev:Int? = nil,ts:Date? = nil,toolUseId:String? = nil,tool:String? = nil,args:JSONValue? = nil,text:String? = nil,result:String? = nil,state:ToolState? = nil,durationMs:Int? = nil){self.id = id;self.rev = rev;self.ts = ts;self.toolUseId = toolUseId;self.tool = tool;self.args = args;self.text = text;self.result = result;self.state = state;self.durationMs = durationMs} }
public struct SubagentEntry: Codable, Sendable, Equatable { public var id:String?;public var rev:Int?;public var ts:Date?;public var toolUseId:String?;public var agentId:String?;public var agent:String?;public var text:String?;public var result:String?;public var state:SubagentState?;public var startedAt:Date?;public var finishedAt:Date?; public init(id:String? = nil,rev:Int? = nil,ts:Date? = nil,toolUseId:String? = nil,agentId:String? = nil,agent:String? = nil,text:String? = nil,result:String? = nil,state:SubagentState? = nil,startedAt:Date? = nil,finishedAt:Date? = nil){self.id = id;self.rev = rev;self.ts = ts;self.toolUseId = toolUseId;self.agentId = agentId;self.agent = agent;self.text = text;self.result = result;self.state = state;self.startedAt = startedAt;self.finishedAt = finishedAt} }
public struct SubagentResultEntry: Codable, Sendable, Equatable { public var id:String?;public var rev:Int?;public var ts:Date?;public var toolUseId:String?;public var agentId:String?;public var agent:String?;public var text:String?;public var state:SubagentState?;public var result:String?;public var durationMs:Int?; public init(id:String? = nil,rev:Int? = nil,ts:Date? = nil,toolUseId:String? = nil,agentId:String? = nil,agent:String? = nil,text:String? = nil,state:SubagentState? = nil,result:String? = nil,durationMs:Int? = nil){self.id = id;self.rev = rev;self.ts = ts;self.toolUseId = toolUseId;self.agentId = agentId;self.agent = agent;self.text = text;self.state = state;self.result = result;self.durationMs = durationMs} }
public struct CompactionEntry: Codable, Sendable, Equatable { public var id:String?;public var rev:Int?;public var ts:Date?;public var text:String?;public init(id:String? = nil,rev:Int? = nil,ts:Date? = nil,text:String? = nil){self.id = id;self.rev = rev;self.ts = ts;self.text = text} }
public struct InterruptEntry: Codable, Sendable, Equatable { public var id:String?;public var rev:Int?;public var ts:Date?;public init(id:String? = nil,rev:Int? = nil,ts:Date? = nil){self.id = id;self.rev = rev;self.ts = ts} }
public struct TurnEndEntry: Codable, Sendable, Equatable { public var id:String?;public var rev:Int?;public var ts:Date?;public var durationMs:Int?;public init(id:String? = nil,rev:Int? = nil,ts:Date? = nil,durationMs:Int? = nil){self.id = id;self.rev = rev;self.ts = ts;self.durationMs = durationMs} }
public struct DecisionEntry: Codable, Sendable, Equatable { public var id:String?;public var rev:Int?;public var ts:Date?;public var sessionId:String?;public var requestId:String?;public var behavior:DecisionBehavior?;public var via:String?;public var text:String?;public var toolName:String?;public var toolInput:JSONValue?;public var permissionMode:String?;public var receivedAt:Date?;public var holdLimitMs:Int?;public var mode:ApprovalMode?;public var status:ApprovalStatus?;public var timedOutAt:Date?;public var permissionSuggestions:[JSONValue]?; public init(id:String? = nil,rev:Int? = nil,ts:Date? = nil,sessionId:String? = nil,requestId:String? = nil,behavior:DecisionBehavior? = nil,via:String? = nil,text:String? = nil,toolName:String? = nil,toolInput:JSONValue? = nil,permissionMode:String? = nil,receivedAt:Date? = nil,holdLimitMs:Int? = nil,mode:ApprovalMode? = nil,status:ApprovalStatus? = nil,timedOutAt:Date? = nil,permissionSuggestions:[JSONValue]? = nil){self.id = id;self.rev = rev;self.ts = ts;self.sessionId = sessionId;self.requestId = requestId;self.behavior = behavior;self.via = via;self.text = text;self.toolName = toolName;self.toolInput = toolInput;self.permissionMode = permissionMode;self.receivedAt = receivedAt;self.holdLimitMs = holdLimitMs;self.mode = mode;self.status = status;self.timedOutAt = timedOutAt;self.permissionSuggestions = permissionSuggestions} }
public enum DecisionBehavior: Codable, Sendable, Equatable { case allow, allowSession, deny, timeout, unknown(String); public init(from d:Decoder)throws{let s = try d.singleValueContainer().decode(String.self);switch s{case "allow":self = .allow;case "allow_session":self = .allowSession;case "deny":self = .deny;case "timeout":self = .timeout;default:self = .unknown(s)}};public func encode(to e:Encoder)throws{var c = e.singleValueContainer();try c.encode(rawValue)};public var rawValue:String{switch self{case .allow:"allow";case .allowSession:"allow_session";case .deny:"deny";case .timeout:"timeout";case .unknown(let s):s}} }
public struct FileEntry: Codable, Sendable, Equatable { public var id:String?;public var rev:Int?;public var ts:Date?;public var sessionId:String?;public var name:String?;public var size:Int?;public var mime:String?;public var url:String?;public init(id:String? = nil,rev:Int? = nil,ts:Date? = nil,sessionId:String? = nil,name:String? = nil,size:Int? = nil,mime:String? = nil,url:String? = nil){self.id = id;self.rev = rev;self.ts = ts;self.sessionId = sessionId;self.name = name;self.size = size;self.mime = mime;self.url = url} }
public struct AttentionEntry: Codable, Sendable, Equatable { public var id:String?;public var rev:Int?;public var ts:Date?;public var text:String?;public init(id:String? = nil,rev:Int? = nil,ts:Date? = nil,text:String? = nil){self.id = id;self.rev = rev;self.ts = ts;self.text = text} }

public enum TranscriptEntry: Codable, Sendable, Equatable {
    case prompt(PromptEntry), assistant(AssistantEntry), tool(ToolEntry), subagent(SubagentEntry), subagentResult(SubagentResultEntry), compaction(CompactionEntry), interrupt(InterruptEntry), turnEnd(TurnEndEntry), decision(DecisionEntry), file(FileEntry), attention(AttentionEntry), unknown(kind: String, raw: JSONValue)

    private enum CodingKeys: String, CodingKey { case kind }
    public init(from decoder: Decoder) throws {
        let kind = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(String.self, forKey: .kind) ?? "unknown"
        switch kind {
        case "prompt": self = .prompt(try PromptEntry(from: decoder))
        case "assistant": self = .assistant(try AssistantEntry(from: decoder))
        case "tool": self = .tool(try ToolEntry(from: decoder))
        case "subagent": self = .subagent(try SubagentEntry(from: decoder))
        case "subagent_result": self = .subagentResult(try SubagentResultEntry(from: decoder))
        case "compaction": self = .compaction(try CompactionEntry(from: decoder))
        case "interrupt": self = .interrupt(try InterruptEntry(from: decoder))
        case "turn_end": self = .turnEnd(try TurnEndEntry(from: decoder))
        case "decision": self = .decision(try DecisionEntry(from: decoder))
        case "file": self = .file(try FileEntry(from: decoder))
        case "attention": self = .attention(try AttentionEntry(from: decoder))
        default: self = .unknown(kind: kind, raw: try JSONValue(from: decoder))
        }
    }
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .prompt(let value): try value.encode(to: encoder)
        case .assistant(let value): try value.encode(to: encoder)
        case .tool(let value): try value.encode(to: encoder)
        case .subagent(let value): try value.encode(to: encoder)
        case .subagentResult(let value): try value.encode(to: encoder)
        case .compaction(let value): try value.encode(to: encoder)
        case .interrupt(let value): try value.encode(to: encoder)
        case .turnEnd(let value): try value.encode(to: encoder)
        case .decision(let value): try value.encode(to: encoder)
        case .file(let value): try value.encode(to: encoder)
        case .attention(let value): try value.encode(to: encoder)
        case .unknown(let kind, let raw):
            guard case .object(var object) = raw else { try raw.encode(to: encoder); return }
            object["kind"] = .string(kind)
            try JSONValue.object(object).encode(to: encoder)
        }
    }

    public var kind: String { switch self { case .prompt: "prompt"; case .assistant: "assistant"; case .tool: "tool"; case .subagent: "subagent"; case .subagentResult: "subagent_result"; case .compaction: "compaction"; case .interrupt: "interrupt"; case .turnEnd: "turn_end"; case .decision: "decision"; case .file: "file"; case .attention: "attention"; case .unknown(let kind, _): kind } }
    public var id: String? { switch self { case .prompt(let v):v.id; case .assistant(let v):v.id; case .tool(let v):v.id; case .subagent(let v):v.id; case .subagentResult(let v):v.id; case .compaction(let v):v.id; case .interrupt(let v):v.id; case .turnEnd(let v):v.id; case .decision(let v):v.id; case .file(let v):v.id; case .attention(let v):v.id; case .unknown(let _, let raw): raw.objectValue?["id"]?.stringValue } }
    public var rev: Int? { switch self { case .prompt(let v):v.rev; case .assistant(let v):v.rev; case .tool(let v):v.rev; case .subagent(let v):v.rev; case .subagentResult(let v):v.rev; case .compaction(let v):v.rev; case .interrupt(let v):v.rev; case .turnEnd(let v):v.rev; case .decision(let v):v.rev; case .file(let v):v.rev; case .attention(let v):v.rev; case .unknown(let _, let raw): raw.objectValue?["rev"]?.intValue } }
    public var ts: Date? { switch self { case .prompt(let v):v.ts; case .assistant(let v):v.ts; case .tool(let v):v.ts; case .subagent(let v):v.ts; case .subagentResult(let v):v.ts; case .compaction(let v):v.ts; case .interrupt(let v):v.ts; case .turnEnd(let v):v.ts; case .decision(let v):v.ts; case .file(let v):v.ts; case .attention(let v):v.ts; case .unknown(let _, let raw): raw.objectValue?["ts"]?.stringValue.flatMap(CCDateCoding.parse) } }
    public var text: String? { switch self { case .prompt(let v):v.text ?? v.command; case .assistant(let v):v.text; case .tool(let v):v.text; case .subagent(let v):v.text; case .subagentResult(let v):v.text; case .compaction(let v):v.text; case .interrupt: nil; case .turnEnd: nil; case .decision(let v):v.text; case .file: nil; case .attention(let v):v.text; case .unknown(let _, let raw): raw.objectValue?["text"]?.stringValue } }
    public var toolUseId: String? { switch self { case .tool(let v):v.toolUseId; case .subagent(let v):v.toolUseId; case .subagentResult(let v):v.toolUseId; default:nil } }
    public var isMeta: Bool { if case .unknown(_, let raw) = self, case .object(let object) = raw { return object["isMeta"]?.stringValue == "true" || object["isMeta"]?.boolValue == true }; return false }
}

private extension JSONValue {
    var boolValue: Bool? { if case .bool(let value) = self { return value }; return nil }
    var objectValue: [String: JSONValue]? { if case .object(let value) = self { return value }; return nil }
    var intValue: Int? { if case .number(let value) = self { return Int(value) }; return nil }
}

public struct TranscriptPage: Codable, Sendable, Equatable { public var entries:[TranscriptEntry];public var total:Int;public var hasMore:Bool;public init(entries:[TranscriptEntry],total:Int,hasMore:Bool){self.entries = entries;self.total = total;self.hasMore = hasMore} }
public struct Decision: Codable, Sendable, Equatable { public var decided:Bool?;public var sessionId:String?;public init(decided:Bool? = nil,sessionId:String? = nil){self.decided = decided;self.sessionId = sessionId} }
