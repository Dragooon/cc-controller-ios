import Foundation

/// Where a read-only Stockade session is answered, as the app names it: "Discord", "the terminal" or "the agent's session".
private func readOnlyPlaceName(_ reason: String?) -> String? {
    switch reason {
    case "discord": "Discord"
    case "terminal": "the terminal"
    case "agent": "the agent's session"
    default: nil
    }
}

/// The bar that replaces the composer on a session the app may only read, such as "Read-only · Discord".
/// Nil when the session is writable or the controller doesn't say (the Mac).
public func readOnlyLabel(for session: Session) -> String? {
    guard session.writable == false else { return nil }
    switch session.readOnlyReason {
    case "discord": return "Read-only · Discord"
    case "terminal": return "Read-only · Terminal"
    case "agent": return "Read-only · Agent"
    default: return "Read-only"
    }
}

/// "Answer in Discord" for an approval Stockade will only take where it was raised. Nil when it can be answered here.
public func answerInLabel(for approval: Approval) -> String? {
    guard let reason = approval.answerIn else { return nil }
    guard let place = readOnlyPlaceName(reason) else { return "Answer where this session runs" }
    return "Answer in \(place)"
}

/// The origin as a short label: Discord, App, Peer or Terminal.
public func sessionOriginLabel(_ origin: String?) -> String? {
    switch origin {
    case "discord": "Discord"
    case "app": "App"
    case "peer": "Peer"
    case "terminal": "Terminal"
    case let value?: value.isEmpty ? nil : value.capitalized
    case nil: nil
    }
}

/// "Started by Kepler" when an agent started the session. A person's own sessions carry no caption.
public func startedByLabel(for session: Session) -> String? {
    guard let starter = session.startedBy, starter.kind == "agent" else { return nil }
    let name = starter.name.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? "Started by an agent" : "Started by \(name)"
}

/// "With sam, riley" when two or more people are in the session.
public func participantsLabel(for session: Session) -> String? {
    let names = (session.participants ?? []).map(\.name).filter { !$0.isEmpty }
    guard names.count >= 2 else { return nil }
    return "With " + names.joined(separator: ", ")
}

/// The Stockade line under a session's name in the list, such as "Madge · Started by Kepler" or "Madge · Discord · read-only".
/// Nil for sessions without D3b fields.
public func stockadeSessionMeta(for session: Session) -> String? {
    guard session.origin != nil || session.writable != nil else { return nil }
    var parts: [String] = []
    if let agent = session.agent {
        parts.append(agent.name ?? agent.id)
    }
    if let startedBy = startedByLabel(for: session) {
        parts.append(startedBy)
    } else if let origin = sessionOriginLabel(session.origin) {
        parts.append(origin)
    }
    if session.writable == false { parts.append("read-only") }
    if session.sudo == true { parts.append("sudo") }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}

/// Whether the composer takes `/sudo` for this session: a Stockade session the app may write, on a controller that advertises `sudo`.
public func acceptsSudo(_ session: Session, capabilities: Set<ControllerCapability>) -> Bool {
    capabilities.contains(.sudo) && session.writable == true
}

/// The toast after `/sudo` toggles: "Sudo on" or "Sudo off".
public func sudoToastText(_ sudo: Bool) -> String {
    sudo ? "Sudo on" : "Sudo off"
}
