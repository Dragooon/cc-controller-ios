import Foundation

/// What a sidebar row shows for its session.
public enum SessionReadStatus: String, Equatable, Sendable {
    case working
    case unread
    case read
}

/// Which sessions' replies this device has shown, kept as text in app storage.
/// Replies from before `baseline`, when the device started keeping marks, count as read.
public struct SessionReadMarks: Equatable, Sendable, Codable {
    public static let storageKey = "sessions.readMarks"

    public private(set) var baseline: Date?
    public private(set) var readThrough: [String: Date]

    public init(baseline: Date? = nil, readThrough: [String: Date] = [:]) {
        self.baseline = baseline
        self.readThrough = readThrough
    }

    public init(stored: String) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let decoded = stored.data(using: .utf8).flatMap { try? decoder.decode(SessionReadMarks.self, from: $0) }
        self = decoded ?? SessionReadMarks()
    }

    public var stored: String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    public mutating func startIfNeeded(now: Date) {
        if baseline == nil { baseline = now }
    }

    public mutating func markRead(key: String, through date: Date) {
        guard !key.isEmpty else { return }
        if let existing = readThrough[key], existing >= date { return }
        readThrough[key] = date
    }

    public func status(for session: Session, key: String, isOpen: Bool) -> SessionReadStatus {
        switch sessionActivity(session) {
        case .working, .background:
            return .working
        case .needsYou:
            if isOpen { return .read }
            // Unread until it's opened after the agent started waiting, whatever the baseline.
            guard let readDate = readThrough[key] else { return .unread }
            guard let waitingDate = sessionWaitingDate(session) else { return .read }
            return waitingDate > readDate ? .unread : .read
        case .idle:
            if isOpen { return .read }
            return hasUnreadReply(at: sessionLastReplyDate(session), key: key) ? .unread : .read
        }
    }

    public func status(for session: SleepingSession, key: String, isOpen: Bool) -> SessionReadStatus {
        if isOpen { return .read }
        return hasUnreadReply(at: session.lastAssistantMessageAt ?? session.lastActiveAt, key: key) ? .unread : .read
    }

    private func hasUnreadReply(at replyDate: Date?, key: String) -> Bool {
        guard let replyDate, let threshold = readThrough[key] ?? baseline else { return false }
        return replyDate > threshold
    }
}

/// When the session started waiting on you, as far as the controller can say.
public func sessionWaitingDate(_ session: Session) -> Date? {
    session.pending?.first?.receivedAt ?? session.idleSince
}

/// When the session's agent last replied, as far as the controller can say.
public func sessionLastReplyDate(_ session: Session) -> Date? {
    session.lastAssistantMessageAt ?? session.idleSince
}
