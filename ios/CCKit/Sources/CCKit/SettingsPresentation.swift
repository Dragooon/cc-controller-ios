import Foundation

public enum SettingsLatency: Sendable, Equatable {
    case checking
    case reachable(Duration)
    case unreachable
}

public enum SettingsConnectionTest: Sendable, Equatable {
    case testing
    case reachable(latency: Duration, at: Date)
    case unreachable(at: Date)
}

public enum SettingsLoad<Value: Sendable & Equatable>: Sendable, Equatable {
    case loading
    case loaded(Value)
    case failed(String)
}

public struct SettingsThisDevice: Sendable, Equatable {
    public var name: String?
    public var pairedAt: Date?
    public var sessionExpiresAt: Date?

    public init(name: String? = nil, pairedAt: Date? = nil, sessionExpiresAt: Date? = nil) {
        self.name = name
        self.pairedAt = pairedAt
        self.sessionExpiresAt = sessionExpiresAt
    }

    public init(whoAmI: WhoAmI) {
        self.init(
            name: nonEmpty(whoAmI.device?.name),
            pairedAt: whoAmI.device?.pairedAt ?? whoAmI.device?.createdAt,
            sessionExpiresAt: whoAmI.sessionExpiresAt
        )
    }
}

/// The three This device values, with loading and failure rendered as text rather than blanks.
public struct SettingsThisDeviceText: Sendable, Equatable {
    public let name: String
    public let paired: String
    public let expiry: String

    public init(
        _ load: SettingsLoad<SettingsThisDevice>,
        now: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) {
        switch load {
        case .loading:
            name = "Loading…"
            paired = "Loading…"
            expiry = "Loading…"
        case .failed:
            name = "Unavailable"
            paired = "Unavailable"
            expiry = "Unavailable"
        case .loaded(let device):
            name = device.name ?? "Unknown"
            paired = pairedDateText(device.pairedAt, locale: locale, timeZone: timeZone)
            expiry = sessionExpiryText(device.sessionExpiresAt, now: now)
        }
    }
}

public struct SettingsPairedDeviceRow: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let lastSeenAt: Date?
    public let isThisDevice: Bool

    public init(id: String, name: String, lastSeenAt: Date?, isThisDevice: Bool) {
        self.id = id
        self.name = name
        self.lastSeenAt = lastSeenAt
        self.isThisDevice = isThisDevice
    }
}

/// Orders the daemon's device list with this iPhone first, then the most recently seen.
public func settingsPairedDeviceRows(_ devices: [Device]) -> [SettingsPairedDeviceRow] {
    let rows = devices.enumerated().map { index, device in
        SettingsPairedDeviceRow(
            id: "\(index)-\(device.createdAt?.timeIntervalSince1970 ?? 0)",
            name: nonEmpty(device.name) ?? "Unnamed device",
            lastSeenAt: device.lastSeenAt,
            isThisDevice: device.thisDevice == true
        )
    }
    return rows.sorted { left, right in
        if left.isThisDevice != right.isThisDevice { return left.isThisDevice }
        let leftSeen = left.lastSeenAt ?? .distantPast
        let rightSeen = right.lastSeenAt ?? .distantPast
        if leftSeen != rightSeen { return leftSeen > rightSeen }
        return left.name.localizedStandardCompare(right.name) == .orderedAscending
    }
}

/// Formats the bundle's marketing version and build for Settings > About.
public func appVersionText(version: String?, build: String?) -> String {
    switch (nonEmpty(version), nonEmpty(build)) {
    case let (version?, build?): return "\(version) (\(build))"
    case let (version?, nil): return version
    case let (nil, build?): return "Build \(build)"
    case (nil, nil): return "Unknown"
    }
}

/// Formats the daemon version and short commit; nil means no bootstrap has been received yet.
public func daemonVersionText(_ daemon: DaemonInfo?) -> String {
    guard let daemon else { return "Unavailable" }
    let commit = nonEmpty(daemon.commit).map { String($0.prefix(7)) }
    switch (nonEmpty(daemon.version), commit) {
    case let (version?, commit?): return "\(version) (\(commit))"
    case let (version?, nil): return version
    case let (nil, commit?): return "Unknown version (\(commit))"
    case (nil, nil): return "Unknown"
    }
}

public func apiVersionText(_ apiVersion: Int?) -> String {
    apiVersion.map(String.init) ?? "Unavailable"
}

public func pairedDateText(_ date: Date?, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
    guard let date else { return "Unknown" }
    return date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, timeZone: timeZone))
}

/// Rounds the remaining session lifetime down, so Settings never promises more time than the bearer has.
public func sessionExpiryText(_ expiresAt: Date?, now: Date) -> String {
    guard let expiresAt else { return "Unknown" }
    let remaining = expiresAt.timeIntervalSince(now)
    guard remaining > 0 else { return "Expired" }
    let minutes = Int(remaining / 60)
    if minutes < 1 { return "in under a minute" }
    if minutes < 60 { return "in \(minutes) min" }
    return "in \(minutes / 60) h"
}

public func lastSeenText(_ lastSeenAt: Date?, now: Date) -> String {
    guard let lastSeenAt else { return "Not seen yet" }
    let minutes = Int(now.timeIntervalSince(lastSeenAt) / 60)
    if minutes < 1 { return "Last seen just now" }
    if minutes < 60 { return "Last seen \(minutes) min ago" }
    let hours = minutes / 60
    if hours < 24 { return "Last seen \(hours) h ago" }
    let days = hours / 24
    return days == 1 ? "Last seen 1 day ago" : "Last seen \(days) days ago"
}

public func settingsLatencyText(_ latency: SettingsLatency) -> String {
    switch latency {
    case .checking: return "Checking…"
    case .reachable(let duration): return latencyText(duration)
    case .unreachable: return "Unreachable"
    }
}

public func connectionTestTitle(_ test: SettingsConnectionTest) -> String {
    switch test {
    case .testing: return "Testing…"
    case .reachable(let latency, _): return "Reachable · \(latencyText(latency))"
    case .unreachable: return "Can't reach the Mac"
    }
}

public func settingsUnreachableGuidance(address: String) -> String {
    "cc-controller can't reach \(address). Check that Termius is forwarding \(address) and the Mac is awake."
}

private func nonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
    return trimmed
}
