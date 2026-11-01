import CoreGraphics
import Foundation

/// The slash commands to suggest for what's in the composer, by the first word typed.
public func slashSuggestions<Command>(text: String, commands: [Command], name: (Command) -> String) -> [Command] {
    guard text.hasPrefix("/") else { return [] }
    let prefix = text.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? text
    return commands.filter { name($0).lowercased().hasPrefix(prefix.lowercased()) }
}

public enum SlashSuggestionAction: Sendable, Equatable {
    case openModelSheet
    case fillComposer(String)
}

/// What tapping a suggestion does. `/model` opens its own sheet; everything else fills the composer.
public func slashSuggestionAction(command: String) -> SlashSuggestionAction {
    command == "/model" ? .openModelSheet : .fillComposer("\(command) ")
}

/// The caption under a message that hasn't reached the transcript yet.
public func pendingNoteStatusText(_ state: QueuedNoteState) -> String {
    switch state {
    case .sending: "Sending…"
    case .sent: "Sent"
    case .queued: "Queued"
    case .failed: "Not sent · Tap to retry"
    }
}

public enum PendingNoteAction: Sendable, Equatable {
    case copy
    case sendAgain
    case retry
    case edit
    case delete
    case dismiss
}

/// The actions a pending message offers, in menu order. A message still sending offers none.
public func pendingNoteActions(state: QueuedNoteState, needsAttention: Bool) -> [PendingNoteAction] {
    if needsAttention { return [.copy, .sendAgain, .edit, .dismiss] }
    switch state {
    case .sending: return []
    case .failed: return [.retry, .edit, .delete]
    case .sent, .queued: return [.copy, .edit, .dismiss]
    }
}

/// A send blocked by an attachment already says why on the attachment's tile, so it raises no alert.
public func shouldPresentSendError(_ error: ActionError) -> Bool {
    guard case .invalid(let message) = error else { return true }
    return message != "Remove or retry the failed attachment"
        && message != "Remove the file that is too large"
}

public enum AttachmentTileState: Sendable, Equatable {
    case uploading(progress: Double)
    case attached
    case failed(reason: String, canRetry: Bool)
}

public func attachmentAccessibilityLabel(name: String, state: AttachmentTileState) -> String {
    switch state {
    case .uploading(let progress):
        progress >= 1 ? "\(name), uploaded, waiting for server" : "\(name), uploading \(Int(progress * 100)) percent"
    case .attached: "\(name), attached"
    case .failed(let reason, let canRetry):
        canRetry ? "\(name), upload failed, double-tap to retry" : "\(name), upload failed, \(reason)"
    }
}

/// How many sessions other than the open one wait on an approval, across every controller.
public func approvalsElsewhereCount(
    approvals: [(controllerID: ControllerID, approvals: [Approval])],
    selected: SessionRef
) -> Int {
    var waiting: Set<SessionRef> = []
    for (controllerID, controllerApprovals) in approvals {
        for approval in controllerApprovals {
            guard let sessionID = approval.sessionId else { continue }
            let session = SessionRef(controllerID: controllerID, sessionID: sessionID)
            if session != selected { waiting.insert(session) }
        }
    }
    return waiting.count
}

/// The inspector's default 320 points plus a usable transcript beside it.
public let minimumDetailWidthWithInspector: CGFloat = 640

/// Whether the inspector and the sidebar can both stay open at this window width. They take turns when not.
public func inspectorFitsBesideSidebar(width: CGFloat, sidebarWidth: CGFloat) -> Bool {
    width - sidebarWidth >= minimumDetailWidthWithInspector
}
