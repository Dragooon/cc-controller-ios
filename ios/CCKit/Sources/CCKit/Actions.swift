import Foundation

public enum ApprovalScope: Sendable, Equatable {
    case once
    case session
}

public enum ActionError: Error, Sendable, Equatable, LocalizedError {
    case unauthorized
    case alreadyAnswered
    case answerInTerminal
    case answersRequired
    case answersInvalid
    case answersKeys
    case answerEmpty
    case answerTooLong
    case waitingInTerminal
    case noPane
    case commandsUnavailable(String)
    case invalid(String)
    case tooLarge(fileName: String, limitBytes: Int)
    case network(String)
    case unreadable(String)
    case timeout
    case server(status: Int, message: String)

    public var userMessage: String {
        switch self {
        case .unauthorized: "Your connection expired. Unlock or pair this device again."
        case .alreadyAnswered: "Already answered elsewhere"
        case .answerInTerminal: "Answer in the terminal"
        case .answersRequired: "Choose an answer for every question."
        case .answersInvalid: "The answers could not be read."
        case .answersKeys: "Answer every question once."
        case .answerEmpty: "Answers cannot be empty."
        case .answerTooLong: "Answers must be 2,000 characters or fewer."
        case .waitingInTerminal: "This approval is waiting in the terminal and cannot be answered here."
        case .noPane: "This session has no tmux pane for that action."
        case .commandsUnavailable(let message): message
        case .invalid(let message): message
        case .tooLarge: "Too large (max 25 MB)"
        case .network(let message): "The Mac could not be reached: \(message)"
        case .unreadable(let message): "The Mac sent a reply this app couldn't read: \(message)"
        case .timeout: "The Mac did not finish that action in time."
        case .server(let status, let message): "The Mac returned HTTP \(status): \(message)"
        }
    }

    public var errorDescription: String? { userMessage }
}

public struct UploadFile: Sendable, Equatable {
    public let name: String
    public let data: Data
    public let mimeType: String?
    public let isImage: Bool
    public let thumbnailData: Data?

    public init(name: String, data: Data, mimeType: String? = nil, isImage: Bool = false, thumbnailData: Data? = nil) {
        self.name = name
        self.data = data
        self.mimeType = mimeType
        self.isImage = isImage
        self.thumbnailData = thumbnailData
    }
}

