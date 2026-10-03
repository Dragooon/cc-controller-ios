import Foundation

public struct PromptCollapse: Codable, Sendable, Equatable {
    public let collapsed: Bool
    public let lineCount: Int
    public let visibleText: String

    public init(collapsed: Bool, lineCount: Int, visibleText: String) {
        self.collapsed = collapsed
        self.lineCount = lineCount
        self.visibleText = visibleText
    }
}

public struct NormalizedPromptText: Codable, Sendable, Equatable {
    public let text: String
    public let attachments: [String]

    public init(text: String, attachments: [String]) {
        self.text = text
        self.attachments = attachments
    }
}

public struct QueuedNote: Codable, Sendable, Equatable {
    public var text: String
    public var queued: Bool
    public var forceSent: Bool
    public var attachments: [String]
    public var attachmentThumbnails: [String: Data]

    public init(
        text: String,
        queued: Bool = false,
        forceSent: Bool = false,
        attachments: [String] = [],
        attachmentThumbnails: [String: Data] = [:]
    ) {
        self.text = text
        self.queued = queued
        self.forceSent = forceSent
        self.attachments = attachments
        self.attachmentThumbnails = attachmentThumbnails
    }

    private enum CodingKeys: String, CodingKey { case text, queued, forceSent, attachments, attachmentThumbnails }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        queued = try container.decodeIfPresent(Bool.self, forKey: .queued) ?? false
        forceSent = try container.decodeIfPresent(Bool.self, forKey: .forceSent) ?? false
        attachments = try container.decodeIfPresent([String].self, forKey: .attachments) ?? []
        attachmentThumbnails = try container.decodeIfPresent([String: Data].self, forKey: .attachmentThumbnails) ?? [:]
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode(queued, forKey: .queued)
        if forceSent { try container.encode(true, forKey: .forceSent) }
        if !attachments.isEmpty { try container.encode(attachments, forKey: .attachments) }
        if !attachmentThumbnails.isEmpty { try container.encode(attachmentThumbnails, forKey: .attachmentThumbnails) }
    }
}

public struct SlashCommandDefinition: Sendable, Equatable {
    public let command: String
    public let description: String

    public init(command: String, description: String) {
        self.command = command
        self.description = description
    }
}

public let defaultSlashCommands: [SlashCommandDefinition] = [
    SlashCommandDefinition(command: "/compact", description: "Summarize context"),
    SlashCommandDefinition(command: "/clear", description: "Clear session"),
    SlashCommandDefinition(command: "/model", description: "Choose model"),
    SlashCommandDefinition(command: "/cost", description: "Show cost"),
    SlashCommandDefinition(command: "/context", description: "Show context"),
    SlashCommandDefinition(command: "/review", description: "Review changes"),
    SlashCommandDefinition(command: "/init", description: "Initialize project"),
    SlashCommandDefinition(command: "/help", description: "Show help")
]

public struct ToolTally: Codable, Sendable, Equatable {
    public let tool: String
    public let count: Int

    public init(tool: String, count: Int) {
        self.tool = tool
        self.count = count
    }
}

public struct ToolRun: Sendable, Equatable {
    public let entries: [ToolEntry]
    public let isRunning: Bool
    public let label: String
    public let tally: [(tool: String, count: Int)]
    public let tallyText: String

    public init(entries: [ToolEntry]) {
        self.entries = entries
        self.isRunning = entries.contains { $0.state == .running }
        self.label = "Ran \(entries.count) tools"
        var counts: [String: Int] = [:]
        var order: [String] = []
        for entry in entries {
            let name = entry.tool ?? "unknown"
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
        }
        self.tally = order.map { ($0, counts[$0] ?? 0) }
        self.tallyText = order.map { name in
            let count = counts[name] ?? 0
            return count > 1 ? "\(name) ×\(count)" : name
        }.joined(separator: " · ")
    }

    public static func == (lhs: ToolRun, rhs: ToolRun) -> Bool {
        lhs.entries == rhs.entries && lhs.isRunning == rhs.isRunning && lhs.label == rhs.label
            && lhs.tally.map(ToolTally.init) == rhs.tally.map(ToolTally.init)
            && lhs.tallyText == rhs.tallyText
    }
}

public enum TurnItem: Sendable, Equatable, Identifiable {
    case assistant(AssistantEntry)
    case tools(ToolRun)
    case subagent(SubagentEntry)
    case subagentResult(SubagentResultEntry)
    case sendMessage(ToolEntry)
    case decision(DecisionEntry)
    case interrupt(InterruptEntry)
    case compaction(CompactionEntry)
    case file(FileEntry)
    case other(TranscriptEntry)

    public var id: String {
        switch self {
        case .assistant(let entry): return entry.stablePresentationID
        case .tools(let run): return run.entries.first?.stablePresentationID ?? "tools"
        case .subagent(let entry): return entry.stablePresentationID
        case .subagentResult(let entry): return entry.stablePresentationID
        case .sendMessage(let entry): return entry.stablePresentationID
        case .decision(let entry): return entry.stablePresentationID
        case .interrupt(let entry): return entry.stablePresentationID
        case .compaction(let entry): return entry.stablePresentationID
        case .file(let entry): return entry.stablePresentationID
        case .other(let entry): return entry.stablePresentationID
        }
    }

    public var kind: String {
        switch self {
        case .assistant: return "assistant"
        case .tools: return "tools"
        case .subagent: return "subagent"
        case .subagentResult: return "subagent_result"
        case .sendMessage: return "sendMessage"
        case .decision: return "decision"
        case .interrupt: return "interrupt"
        case .compaction: return "compaction"
        case .file: return "file"
        case .other(let entry): return entry.kind
        }
    }
}

public struct Turn: Identifiable, Sendable, Equatable {
    public let id: String
    public let prompts: [PromptEntry]
    public let items: [TurnItem]
    public let end: TurnEndEntry?
    public let durationMs: Int
    public let hasBody: Bool
    public let live: Bool
    public let hasWorkedFooter: Bool

    public init(id: String, prompts: [PromptEntry], items: [TurnItem], end: TurnEndEntry?, durationMs: Int, hasBody: Bool, live: Bool, hasWorkedFooter: Bool) {
        self.id = id
        self.prompts = prompts
        self.items = items
        self.end = end
        self.durationMs = durationMs
        self.hasBody = hasBody
        self.live = live
        self.hasWorkedFooter = hasWorkedFooter
    }
}

public struct PermissionCopy: Codable, Sendable, Equatable {
    public let header: String
    public let command: String
    public let description: String
    public let question: String
    public let holdLimitMs: Int

    public init(header: String, command: String, description: String, question: String, holdLimitMs: Int) {
        self.header = header
        self.command = command
        self.description = description
        self.question = question
        self.holdLimitMs = holdLimitMs
    }
}

public struct EntryFields: Codable, Sendable, Equatable {
    public let kind: String
    public let text: String
    public let attachments: [String]
    public let paste: Paste?
    public let command: String?
    public let model: String?
    public let toolUseId: String
    public let tool: String
    public let args: JSONValue
    public let result: String
    public let summary: String
    public let state: String
    public let time: Date?
    public let agent: String
    public let agentId: String
    public let startedAt: Date?
    public let finishedAt: Date?
    public let durationMs: Int?
    public let behavior: String
    public let name: String
    public let size: Int
    public let mime: String
    public let url: String

    public init(kind: String, text: String = "", attachments: [String] = [], paste: Paste? = nil, command: String? = nil, model: String? = nil, toolUseId: String = "", tool: String = "unknown", args: JSONValue = .object([:]), result: String = "", summary: String = "", state: String = "done", time: Date? = nil, agent: String = "agent", agentId: String = "", startedAt: Date? = nil, finishedAt: Date? = nil, durationMs: Int? = nil, behavior: String = "", name: String = "", size: Int = 0, mime: String = "", url: String = "") {
        self.kind = kind
        self.text = text
        self.attachments = attachments
        self.paste = paste
        self.command = command
        self.model = model
        self.toolUseId = toolUseId
        self.tool = tool
        self.args = args
        self.result = result
        self.summary = summary
        self.state = state
        self.time = time
        self.agent = agent
        self.agentId = agentId
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.durationMs = durationMs
        self.behavior = behavior
        self.name = name
        self.size = size
        self.mime = mime
        self.url = url
    }
}

public struct ActivityFooter: Codable, Sendable, Equatable {
    public let primary: String
    public let detail: String

    public init(primary: String, detail: String) {
        self.primary = primary
        self.detail = detail
    }
}

public let spinnerVerbs: [String] = [
    "Accomplishing", "Actioning", "Actualizing", "Architecting", "Baking", "Beaming", "Beboppin'", "Befuddling", "Billowing", "Blanching", "Bloviating", "Boogieing", "Boondoggling", "Booping", "Bootstrapping", "Brewing", "Bunning", "Burrowing", "Calculating", "Canoodling", "Caramelizing", "Cascading", "Catapulting", "Cerebrating", "Channeling", "Choreographing", "Churning", "Clauding", "Coalescing", "Cogitating", "Combobulating", "Composing", "Computing", "Concocting", "Considering", "Contemplating", "Cooking", "Crafting", "Creating", "Crunching", "Crystallizing", "Cultivating", "Deciphering", "Deliberating", "Determining", "Dilly-dallying", "Discombobulating", "Doing", "Doodling", "Drizzling", "Ebbing", "Effecting", "Elucidating", "Embellishing", "Enchanting", "Envisioning", "Fermenting", "Fiddle-faddling", "Finagling", "Flambéing", "Flibbertigibbeting", "Flowing", "Flummoxing", "Fluttering", "Forging", "Forming", "Frolicking", "Frosting", "Gallivanting", "Galloping", "Garnishing", "Generating", "Gesticulating", "Germinating", "Gitifying", "Grooving", "Gusting", "Harmonizing", "Hashing", "Hatching", "Herding", "Honking", "Hullaballooing", "Hyperspacing", "Ideating", "Imagining", "Improvising", "Incubating", "Inferring", "Infusing", "Ionizing", "Jitterbugging", "Julienning", "Kerfuffling", "Kneading", "Leavening", "Levitating", "Lollygagging", "Manifesting", "Marinating", "Meandering", "Metamorphosing", "Misting", "Moonwalking", "Moseying", "Mulling", "Mustering", "Musing", "Nebulizing", "Nesting", "Newspapering", "Noodling", "Nucleating", "Onioning", "Orbiting", "Orchestrating", "Osmosing", "Perambulating", "Percolating", "Perusing", "Philosophizing", "Photosynthesizing", "Polishing", "Pollinating", "Pondering", "Pontificating", "Pouncing", "Precipitating", "Prestidigitating", "Processing", "Proofing", "Propagating", "Puttering", "Puzzling", "Quantumizing", "Razzle-dazzling", "Razzmatazzing", "Recombobulating", "Reticulating", "Roosting", "Ruminating", "Sautéing", "Scampering", "Schlepping", "Scurrying", "Seasoning", "Shenaniganing", "Shimmying", "Simmering", "Skedaddling", "Sketching", "Slithering", "Smooshing", "Sock-hopping", "Spelunking", "Spinning", "Sprouting", "Stewing", "Sublimating", "Swirling", "Swooping", "Symbioting", "Synthesizing", "Tempering", "Thinking", "Thundering", "Tinkering", "Tomfoolering", "Topsy-turvying", "Transfiguring", "Transmogrifying", "Transmuting", "Twisting", "Undulating", "Unfurling", "Unraveling", "Vibing", "Waddling", "Wandering", "Warping", "Whatchamacalliting", "Whirlpooling", "Whirring", "Whisking", "Wibbling", "Working", "Wrangling", "Zesting", "Zigzagging"
]

public func actionGlyph(state: String?) -> String {
    if state == "needs_you" { return "⏺" }
    if state == "working" { return "✻" }
    return "○"
}

public func stateLabel(state: String?) -> String {
    switch state {
    case "needs_you": return "needs you"
    case "working": return "working"
    case "idle": return "idle"
    case "ended": return "ended"
    default: return (state ?? "idle").replacingOccurrences(of: "_", with: " ")
    }
}

public func subagentStateLabel(state: String?) -> String {
    switch state {
    case "running": return "Running"
    case "done": return "Done"
    case "stopped": return "stopped"
    case "failed": return "failed"
    default: return (state ?? "done").replacingOccurrences(of: "_", with: " ")
    }
}

public func formatModelName(_ model: String?) -> String {
    let value = (model ?? "").trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "claude-", with: "", options: [.caseInsensitive, .anchored])
    guard !value.isEmpty else { return "" }
    let parts = value.split(separator: "-").map(String.init)
    var words: [String] = []
    var digits: [String] = []
    for part in parts {
        if part.range(of: "^[0-9]+$", options: .regularExpression) != nil { digits.append(part) }
        else if !part.isEmpty { words.append(part) }
    }
    let label = (words + (digits.isEmpty ? [] : [digits.joined(separator: ".")])).joined(separator: " ")
    guard !label.isEmpty else { return value }
    return label.prefix(1).uppercased() + label.dropFirst()
}

public func composerModelName(_ model: String?) -> String? {
    let value = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !value.isEmpty else { return nil }
    let lowered = value.lowercased()
    guard !lowered.contains("unknown"), lowered != "placeholder", lowered != "model" else { return nil }
    let formatted = formatModelName(value)
    return formatted.isEmpty ? nil : formatted
}

public func formatTime(_ value: Date?, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
    guard let value else { return "" }
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.timeZone = timeZone
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: value)
}

public func formatCountdown(_ milliseconds: Double) -> String {
    let seconds = max(0, Int(ceil(milliseconds / 1000)))
    return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
}

public func chooseSpinnerVerb(random: Double = Double.random(in: 0..<1)) -> String {
    guard !spinnerVerbs.isEmpty else { return "Working" }
    let clamped = min(Double(spinnerVerbs.count - 1), max(0, floor(random * Double(spinnerVerbs.count))))
    return spinnerVerbs[Int(clamped)]
}

public func turnOutputTokens(_ entries: [TranscriptEntry]) -> Int? {
    var total = 0
    var found = false
    for entry in entries {
        guard case .assistant(let assistant) = entry else { continue }
        let value = assistant.usage?.outputTokens ?? assistant.usage?.outputTokensSnake ?? assistant.outputTokensSnake
        guard let value else { continue }
        total += value
        found = true
    }
    return found ? total : nil
}

public func formatDuration(_ milliseconds: Double) -> String {
    let seconds = max(0, Int((milliseconds / 1000).rounded()))
    if seconds < 60 { return "\(seconds)s" }
    let minutes = seconds / 60
    let remainingSeconds = seconds % 60
    if minutes < 60 { return "\(minutes)m \(remainingSeconds)s" }
    return "\(minutes / 60)h \((minutes % 60))m \(remainingSeconds)s"
}

public func formatListDuration(_ milliseconds: Double) -> String {
    let seconds = Int(max(0, milliseconds) / 1000)
    if seconds < 60 { return "\(seconds)s" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h \(minutes % 60)m" }
    return "\(hours / 24)d \(hours % 24)h"
}

public func formatTokenCount(_ value: Double) -> String {
    guard value.isFinite else { return "" }
    let absolute = abs(value)
    let sign = value < 0 ? "-" : ""
    if absolute >= 1_000_000 { return "\(sign)\(formatUnit(absolute / 1_000_000))M" }
    if absolute >= 1_000 { return "\(sign)\(formatUnit(absolute / 1_000))k" }
    return "\(Int(value.rounded()))"
}

public func formatTokenCount(_ value: Int?) -> String {
    guard let value else { return "" }
    return formatTokenCount(Double(value))
}

public func formatTokenUsageSegments(_ usage: Usage?) -> [String] {
    guard let usage else { return [] }
    var segments: [String] = []
    if let input = usage.totalInputTokens ?? usage.inputTokens, input > 0 {
        segments.append("\(formatTokenCount(input)) in")
    }
    if let output = usage.outputTokens, output > 0 {
        segments.append("\(formatTokenCount(output)) out")
    }
    if let cacheHitRate = usage.cacheHitRate, cacheHitRate.isFinite, cacheHitRate > 0 {
        let percent = cacheHitRate <= 1 ? cacheHitRate * 100 : cacheHitRate
        if percent > 0 { segments.append("cache \(Int(percent.rounded()))%") }
    }
    return segments
}

public func formatContextUsage(_ usage: Usage? = nil, expanded: Bool = false) -> String {
    guard let usage else { return "" }
    if expanded, let contextTokens = usage.contextTokens, let contextWindow = usage.contextWindow {
        return "ctx \(formatTokenCount(contextTokens)) / \(formatTokenCount(contextWindow))"
    }
    guard let percent = usage.contextPercent, percent.rounded() > 0 else { return "" }
    return "ctx \(formatTokenCount(Double(percent.rounded())))%"
}

public func sessionStateSegment(_ session: Session, now: Date = .now) -> String {
    if session.state == .working {
        let elapsed = elapsedMilliseconds(from: session.startedAt, to: now)
        return "working \(formatDuration(elapsed))"
    }
    if session.state == .idle, let idleSince = session.idleSince {
        return "idle \(formatDuration(elapsedMilliseconds(from: idleSince, to: now)))"
    }
    if session.state == .needsYou, let receivedAt = session.pending?.first?.receivedAt {
        return "needs you \(formatDuration(elapsedMilliseconds(from: receivedAt, to: now)))"
    }
    return stateLabel(state: session.state?.rawValue)
}

public func sessionListStateSegment(_ session: Session, now: Date = .now) -> String {
    if session.state == .working {
        return "working \(formatListDuration(elapsedMilliseconds(from: session.startedAt, to: now)))"
    }
    if session.state == .idle, let idleSince = session.idleSince {
        return "idle \(formatListDuration(elapsedMilliseconds(from: idleSince, to: now)))"
    }
    if session.state == .needsYou, let receivedAt = session.pending?.first?.receivedAt {
        return "needs you \(formatListDuration(elapsedMilliseconds(from: receivedAt, to: now)))"
    }
    return stateLabel(state: session.state?.rawValue)
}

public func buildStatusSegments(_ session: Session, now: Date = .now, contextExpanded: Bool = false) -> [String] {
    let usage = session.usage
    var segments: [String] = []
    let model = formatModelName(usage?.model)
    if !model.isEmpty { segments.append(model) }
    if session.state != nil { segments.append(sessionStateSegment(session, now: now)) }
    let subagents = session.subagents ?? []
    let running = subagents.filter { $0.state == .running }.count
    let count = running == 0 ? subagents.count : running
    if count > 0 { segments.append("\(count) agent\(count == 1 ? "" : "s") ▸") }
    let context = formatContextUsage(usage, expanded: contextExpanded)
    if !context.isEmpty { segments.append(context) }
    if let input = usage?.totalInputTokens ?? usage?.inputTokens { segments.append("\(formatTokenCount(input)) in") }
    if let output = usage?.outputTokens { segments.append("\(formatTokenCount(output)) out") }
    if let cacheHitRate = usage?.cacheHitRate, cacheHitRate.isFinite {
        let percent = cacheHitRate <= 1 ? cacheHitRate * 100 : cacheHitRate
        segments.append("cache \(Int(percent.rounded()))%")
    }
    return segments
}

public func sessionNavSubtitle(_ session: Session, now: Date = .now, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
    let state = session.state == .needsYou ? "needs you" : session.state?.rawValue ?? "idle"
    let started = session.state == .working ? session.startedAt : session.idleSince
    let elapsed = started.map { " · \(formatDuration(elapsedMilliseconds(from: $0, to: now)))" } ?? ""
    let count = session.subagents?.count ?? 0
    let agents = count == 0 ? "" : " · \(count) agent\(count == 1 ? "" : "s")"
    let context = formatContextUsage(session.usage)
    let contextSegment = context.isEmpty ? "" : " · \(context.replacingOccurrences(of: "%", with: " %"))"
    return "\(state)\(elapsed)\(agents)\(contextSegment)"
}

public func resolveSendMessageTarget(_ to: String?, subagents: [Subagent] = []) -> String {
    let target = to ?? ""
    return subagents.first(where: { $0.agentId == target })?.agent ?? target
}

public func sendMessageSummary(args: [String: JSONValue] = [:]) -> String {
    if let summary = args["summary"]?.stringValue, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return firstMeaningfulLine(summary) }
    if let message = args["message"]?.stringValue { return firstMeaningfulLine(message) }
    if case .object(let message)? = args["message"], let text = message["text"]?.stringValue ?? message["content"]?.stringValue { return firstMeaningfulLine(text) }
    return ""
}

public func formatSendMessage(args: [String: JSONValue] = [:], subagents: [Subagent] = []) -> String {
    let rawTarget = args["to"]?.stringValue ?? args["recipient"]?.stringValue
    let target = resolveSendMessageTarget(rawTarget, subagents: subagents)
    let summary = sendMessageSummary(args: args)
    if target.isEmpty { return summary.isEmpty ? "→" : "→ \(summary)" }
    return summary.isEmpty ? "→ \(target)" : "→ \(target) · \(summary)"
}

public func earlierTurnCount(totalTurns: Int, visibleTurns: Int = 20) -> Int {
    max(0, totalTurns - visibleTurns)
}

public func displayText(_ value: String?) -> String {
    (value ?? "").replacingOccurrences(of: "/Users/owner", with: "~")
}

public func firstMeaningfulLine(_ value: String?) -> String {
    for line in (value ?? "").split(whereSeparator: \ .isNewline).map(String.init) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.range(of: "^#{1,6}(?:\\s|$)", options: .regularExpression) != nil || trimmed.range(of: "^(?:[-*_]\\s*){3,}$", options: .regularExpression) != nil || trimmed.range(of: "^(?:\\*\\*|__)\\s*[^*_]+?\\s*(?:\\*\\*|__)\\s*:?$", options: .regularExpression) != nil || trimmed.range(of: "^\\[harness:", options: [.regularExpression, .caseInsensitive]) != nil { continue }
        return trimmed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
    return ""
}

public func promptCollapse(_ text: String?, maxLines: Int = 8, collapsedLines: Int = 4, charsPerLine: Int = 48, renderedLines: Int? = nil, hasPaste: Bool = false) -> PromptCollapse {
    let source = text ?? ""
    let lines = source.components(separatedBy: .newlines)
    let estimated = lines.reduce(0) { $0 + max(1, Int(ceil(Double($1.count) / Double(charsPerLine)))) }
    let lineCount = renderedLines.map { max(0, $0) } ?? estimated
    let collapsed = hasPaste || lineCount > maxLines
    return PromptCollapse(collapsed: collapsed, lineCount: lineCount, visibleText: collapsed ? lines.prefix(collapsedLines).joined(separator: "\n") : source)
}

public func normalisePromptText(_ value: String?) -> NormalizedPromptText {
    let source = value ?? ""
    guard let match = source.range(of: "\\nAttached files:\\s*\\n((?:\\s*-\\s*.+(?:\\r?\\n|$))+)[ \\t]*$", options: [.regularExpression, .caseInsensitive]) else {
        return NormalizedPromptText(text: source, attachments: [])
    }
    let suffix = String(source[match])
    let lines = suffix.split(whereSeparator: \ .isNewline).dropFirst().map(String.init)
    let attachments = lines.map { line in
        let path = line.replacingOccurrences(of: "^\\s*-\\s*", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
    }.filter { !$0.isEmpty }
    let text = String(source[..<match.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    return NormalizedPromptText(text: text, attachments: attachments)
}

public func toolArgument(_ tool: String?, args: JSONValue? = nil) -> String {
    let name = tool ?? ""
    let input: [String: JSONValue]
    if case .object(let object) = args { input = object } else { input = [:] }
    let preferred: [String]
    switch name {
    case "Bash": preferred = ["command"]
    case "Read", "Edit", "Write": preferred = ["file_path", "path"]
    case "Grep", "Glob": preferred = ["pattern"]
    case "Agent", "Task": preferred = ["description"]
    case "WebFetch": preferred = ["url"]
    case "Skill": preferred = ["skill"]
    default: preferred = []
    }
    for key in preferred where input[key]?.stringValue != nil { return input[key]?.stringValue ?? "" }
    if let value = input.values.first(where: { $0.stringValue != nil })?.stringValue { return value }
    return input.keys.first ?? ""
}

public func activityLineText(_ session: Session) -> String {
    if session.toolRunning == true, let tool = session.lastTool, !tool.isEmpty {
        let argument = toolArgument(tool, args: session.lastToolInput)
        let detail = firstMeaningfulLine(argument).prefix(120)
        return detail.isEmpty ? tool : "\(tool) · \(detail)"
    }
    let running = (session.subagents ?? []).filter { $0.state == .running }
    if !running.isEmpty {
        let names = running.map { $0.agent ?? "agent" }.joined(separator: ", ")
        return "\(running.count) agent\(running.count == 1 ? "" : "s") running · \(names)"
    }
    return "thinking"
}

public func mergeTranscriptEntries(snapshot: [TranscriptEntry] = [], local: [TranscriptEntry] = []) -> [TranscriptEntry] {
    var merged = snapshot
    var seen = Set(snapshot.map(transcriptEntryKey))
    for entry in local {
        let key = transcriptEntryKey(entry)
        guard !seen.contains(key) else { continue }
        seen.insert(key)
        merged.append(entry)
    }
    return merged.sorted { left, right in
        guard let leftDate = left.ts, let rightDate = right.ts else { return false }
        return leftDate < rightDate
    }
}

public func groupTranscript(entries: [TranscriptEntry] = [], working: Bool = false, now: Date = .now) -> [Turn] {
    groupTurns(entries: entries, working: working, now: now)
}

public func groupTurns(entries: [TranscriptEntry] = [], working: Bool = false, now: Date = .now) -> [Turn] {
    var rawTurns: [RawTurn] = []
    for entry in entries {
        if entry.isMeta || entry.kind == "attention" { continue }
        if case .prompt(let prompt) = entry {
            if let index = rawTurns.indices.last, rawTurns[index].entries.isEmpty, rawTurns[index].end == nil, !rawTurns[index].prompts.isEmpty {
                rawTurns[index].prompts.append(prompt)
            } else {
                rawTurns.append(RawTurn(prompts: [prompt]))
            }
            continue
        }
        if rawTurns.isEmpty { rawTurns.append(RawTurn()) }
        if case .turnEnd(let end) = entry { rawTurns[rawTurns.count - 1].end = end }
        else { rawTurns[rawTurns.count - 1].entries.append(entry) }
    }
    return rawTurns.enumerated().map { index, raw in
        let first = raw.prompts.first?.ts ?? raw.entries.first?.ts
        let last = raw.entries.last?.ts ?? first ?? now
        let duration: Double
        if let endTimestamp = raw.end?.ts {
            duration = max(0, endTimestamp.timeIntervalSince(first ?? endTimestamp) * 1000)
        } else if let declared = raw.end?.durationMs {
            duration = Double(declared)
        } else {
            let end = working && index == rawTurns.count - 1 ? now : last
            duration = max(0, end.timeIntervalSince(first ?? end) * 1000)
        }
        let hasBody = raw.end != nil || raw.entries.contains { ["assistant", "tool", "subagent", "subagent_result"].contains($0.kind) }
        let live = working && index == rawTurns.count - 1 && raw.end == nil
        let id = raw.prompts.first?.stablePresentationID ?? raw.entries.first?.stablePresentationID ?? "turn-\(index)"
        return Turn(id: id, prompts: raw.prompts, items: groupTurnItems(raw.entries), end: raw.end, durationMs: Int(duration.rounded()), hasBody: hasBody, live: live, hasWorkedFooter: !working && index == rawTurns.count - 1 && raw.entries.last?.kind == "assistant")
    }
}

public func groupToolEntries(_ entries: [TranscriptEntry]) -> [TurnItem] {
    groupTurnItems(entries)
}

public func workedFooterText(_ turn: Turn) -> String? {
    turn.hasWorkedFooter ? "✻ Worked for \(formatDuration(Double(turn.durationMs)))" : nil
}

public func liveFooterText(_ turn: Turn, verb: String) -> String {
    let latest = turn.items.last
    if case .tools(let run) = latest, let tool = run.entries.last, tool.state == .running {
        let elapsed = elapsedMilliseconds(from: tool.ts, to: .now)
        return "✻ \(verb)… (running tool for \(formatDuration(elapsed)))"
    }
    let tokenText = turnOutputTokens(turn.items.compactMap { item in
        if case .assistant(let assistant) = item { return .assistant(assistant) }
        return nil
    }).map { " · ↓ \(formatTokenCount($0)) tokens" } ?? ""
    return "✻ \(verb)… (\(formatDuration(Double(turn.durationMs)))\(tokenText))"
}

public func activityFooterText(_ session: Session, now: Date = .now, verb: String) -> ActivityFooter {
    let elapsed = elapsedMilliseconds(from: session.startedAt, to: now)
    let tokenText = session.usage?.outputTokens.map { " · ↓ \(formatTokenCount($0)) tokens" } ?? ""
    return ActivityFooter(primary: "✻ \(verb)… (\(formatDuration(elapsed))\(tokenText))", detail: activityLineText(session))
}

public func permissionCopy(_ approval: Approval, timeZone: TimeZone = .current, locale: Locale = .current) -> PermissionCopy {
    let tool = approval.toolName ?? "Permission request"
    let input = approval.toolInput
    let argument: JSONValue?
    if tool == "Bash" {
        argument = objectValue(input)?["command"]
    } else {
        let object = objectValue(input) ?? [:]
        argument = object["file_path"] ?? object["path"] ?? object["query"] ?? object["url"] ?? object.first(where: { $0.key != "description" })?.value
    }
    let command = argument.flatMap(approvalArgumentText) ?? ""
    let agent = approval.agentType.map { $0 != "kepler" ? $0 : "Claude" } ?? "Claude"
    return PermissionCopy(header: "\(tool)\(tool == "Bash" ? " command" : "")", command: command, description: objectValue(input)?["description"]?.stringValue ?? "", question: "\(agent) wants to run this. Do you want to proceed?", holdLimitMs: approval.holdLimitMs ?? 600_000)
}

public func nowSubtitle(total: Int, needsYou: Int) -> String {
    let base = "\(total) sessions"
    return needsYou > 0 ? "\(base), \(needsYou) needs you" : base
}

public func composeSessionState(_ session: Session, now: Date = .now, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
    if session.state == .needsYou { return "needs you" }
    if session.state == .working {
        let prefix = session.lastTool.map { "Running \($0)" } ?? "Working"
        return "\(prefix), \(formatDuration(elapsedMilliseconds(from: session.startedAt, to: now))) in"
    }
    if session.state == .idle {
        return session.idleSince.map { "Idle since \(formatTime($0, timeZone: timeZone, locale: locale))" } ?? "Idle"
    }
    return stateLabel(state: session.state?.rawValue)
}

public func entryFields(_ entry: TranscriptEntry) -> EntryFields {
    switch entry {
    case .prompt(let value):
        let normalized = normalisePromptText(value.text ?? value.command)
        return EntryFields(kind: "prompt", text: normalized.text, attachments: normalized.attachments, paste: value.paste, command: value.command)
    case .assistant(let value):
        return EntryFields(kind: "assistant", text: value.text ?? "", model: value.model)
    case .tool(let value):
        return EntryFields(kind: "tool", text: value.text ?? "", toolUseId: value.toolUseId ?? "", tool: value.tool ?? "unknown", args: value.args ?? .object([:]), result: value.result ?? "", summary: value.text ?? "", state: value.state?.rawValue ?? "done", time: value.ts)
    case .subagent(let value):
        return EntryFields(kind: "subagent", text: value.text ?? "", toolUseId: value.toolUseId ?? "", result: value.result ?? "", state: value.state?.rawValue ?? "running", time: value.ts, agent: value.agent ?? "agent", agentId: value.agentId ?? "", startedAt: value.startedAt, finishedAt: value.finishedAt)
    case .subagentResult(let value):
        return EntryFields(kind: "subagent_result", text: value.text ?? "", toolUseId: value.toolUseId ?? "", result: value.result ?? "", state: value.state?.rawValue ?? "done", time: value.ts, agent: value.agent ?? "agent", agentId: value.agentId ?? "", durationMs: value.durationMs)
    case .interrupt: return EntryFields(kind: "interrupt")
    case .compaction(let value): return EntryFields(kind: "compaction", text: value.text ?? "", time: value.ts)
    case .decision(let value): return EntryFields(kind: "decision", text: value.text ?? decisionText(value), behavior: value.behavior?.rawValue ?? "")
    case .file(let value): return EntryFields(kind: "file", name: value.name ?? "", size: value.size ?? 0, mime: value.mime ?? "", url: value.url ?? "")
    case .attention(let value): return EntryFields(kind: "attention", text: value.text ?? "")
    case .turnEnd: return EntryFields(kind: "turn_end")
    case .unknown(let kind, let raw): return EntryFields(kind: kind, text: objectValue(raw)?["text"]?.stringValue ?? "")
    }
}

public func decisionText(_ entry: DecisionEntry, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
    let text: String
    switch entry.behavior {
    case .deny: text = "Denied from this device"
    case .allowSession: text = "Allowed for this session from this device"
    case .allow: text = "Allowed from this device"
    case .timeout: text = "Approval timed out; waiting in the terminal"
    default: text = "Approval settled"
    }
    let time = formatTime(entry.ts ?? entry.receivedAt, timeZone: timeZone, locale: locale)
    return time.isEmpty ? text : "\(text), \(time)"
}

public func reconcileQueuedNote(_ queuedEntries: [QueuedNote], promptEntry: TranscriptEntry) -> [QueuedNote] {
    guard case .prompt(let prompt) = promptEntry else { return queuedEntries }
    let transcriptText = (normalisePromptText(prompt.text ?? prompt.command).text).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !transcriptText.isEmpty else { return queuedEntries }
    return queuedEntries.filter { note in
        let provisional = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return provisional.isEmpty || (transcriptText != provisional && !transcriptText.hasPrefix(provisional))
    }
}

public func formatSize(_ size: Int) -> String {
    if size < 1024 { return "\(size) B" }
    if size < 1024 * 1024 { return "\(Int((Double(size) / 1024).rounded())) KB" }
    return String(format: "%.1f MB", Double(size) / (1024 * 1024))
}

private struct RawTurn {
    var prompts: [PromptEntry] = []
    var entries: [TranscriptEntry] = []
    var end: TurnEndEntry?
}

private func groupTurnItems(_ entries: [TranscriptEntry]) -> [TurnItem] {
    var items: [TurnItem] = []
    var tools: [ToolEntry] = []
    func flush() {
        guard !tools.isEmpty else { return }
        if tools.count == 1, tools[0].tool == "SendMessage" { items.append(.sendMessage(tools[0])) }
        else { items.append(.tools(ToolRun(entries: tools))) }
        tools.removeAll(keepingCapacity: true)
    }
    for entry in entries {
        if case .tool(let tool) = entry {
            tools.append(tool)
            continue
        }
        flush()
        switch entry {
        case .assistant(let value): items.append(.assistant(value))
        case .subagent(let value): items.append(.subagent(value))
        case .subagentResult(let value): items.append(.subagentResult(value))
        case .decision(let value): items.append(.decision(value))
        case .interrupt(let value): items.append(.interrupt(value))
        case .compaction(let value): items.append(.compaction(value))
        case .file(let value): items.append(.file(value))
        default: items.append(.other(entry))
        }
    }
    flush()
    return items
}

private func transcriptEntryKey(_ entry: TranscriptEntry) -> String {
    if entry.kind == "tool" || entry.kind == "subagent" { return "\(entry.kind)|\(entry.toolUseId ?? "")" }
    return "\(entry.ts.map(CCDateCoding.format) ?? "")|\(entry.kind)|\(entry.text ?? "")"
}

private func elapsedMilliseconds(from start: Date?, to end: Date) -> Double {
    guard let start else { return 0 }
    return max(0, end.timeIntervalSince(start) * 1000)
}

private func formatUnit(_ value: Double) -> String {
    if value < 10, value.rounded() != value { return String(format: "%.1f", value) }
    return String(Int(value.rounded()))
}

private func objectValue(_ value: JSONValue?) -> [String: JSONValue]? {
    guard case .object(let object) = value else { return nil }
    return object
}

private func approvalArgumentText(_ value: JSONValue) -> String? {
    if let string = value.stringValue { return string }
    guard case .object = value else { return nil }
    do {
        let data = try JSONEncoder.ccKit().encode(value)
        let object = try JSONSerialization.jsonObject(with: data)
        let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        return String(data: pretty, encoding: .utf8)
    } catch {
        return nil
    }
}

private extension TranscriptEntry {
    var stablePresentationID: String { id ?? presentationID }
    var presentationID: String { "\(kind)|\(ts.map(CCDateCoding.format) ?? "")|\(text ?? "")" }
}

private extension PromptEntry {
    var stablePresentationID: String { id ?? "prompt|\(ts.map(CCDateCoding.format) ?? "")|\(text ?? command ?? "")" }
}

private extension AssistantEntry {
    var stablePresentationID: String { id ?? "assistant|\(ts.map(CCDateCoding.format) ?? "")|\(text ?? "")" }
}

private extension ToolEntry {
    var stablePresentationID: String { id ?? "tool|\(toolUseId ?? "")" }
}

private extension SubagentEntry {
    var stablePresentationID: String { id ?? "subagent|\(toolUseId ?? "")" }
}

private extension SubagentResultEntry {
    var stablePresentationID: String { id ?? "subagent_result|\(toolUseId ?? "")" }
}

private extension DecisionEntry {
    var stablePresentationID: String { id ?? "decision|\(requestId ?? "")|\(behavior?.rawValue ?? "")" }
}

private extension InterruptEntry {
    var stablePresentationID: String { id ?? "interrupt|\(ts.map(CCDateCoding.format) ?? "")" }
}

private extension CompactionEntry {
    var stablePresentationID: String { id ?? "compaction|\(ts.map(CCDateCoding.format) ?? "")" }
}

private extension FileEntry {
    var stablePresentationID: String { id ?? "file|\(name ?? "")" }
}

private func selfAssign<T>(_ target: inout T?, _ value: T) { target = value }
