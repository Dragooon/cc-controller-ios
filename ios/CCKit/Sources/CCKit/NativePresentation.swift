import Foundation

public func sessionsSubtitle(_ sessions: [Session]) -> String? {
    guard !sessions.isEmpty else { return nil }
    if sessions.allSatisfy({ $0.state == .idle }) { return "All idle" }

    let needsYou = sessions.filter { $0.state == .needsYou }.count
    let working = sessions.filter { $0.state == .working }.count
    var parts: [String] = []
    if needsYou > 0 { parts.append("\(needsYou) needs you") }
    if working > 0 { parts.append("\(working) working") }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}
