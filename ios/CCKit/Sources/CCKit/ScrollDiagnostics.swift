import Foundation
import OSLog

public struct ScrollGuardGeometry: Equatable, Sendable {
    public let contentOffsetY: CGFloat
    public let contentHeight: CGFloat
    public let containerHeight: CGFloat
    public let insetTop: CGFloat
    public let insetBottom: CGFloat
    public let visibleMinY: CGFloat
    public let visibleMaxY: CGFloat

    public init(
        contentOffsetY: CGFloat,
        contentHeight: CGFloat,
        containerHeight: CGFloat,
        insetTop: CGFloat,
        insetBottom: CGFloat,
        visibleMinY: CGFloat,
        visibleMaxY: CGFloat
    ) {
        self.contentOffsetY = contentOffsetY
        self.contentHeight = contentHeight
        self.containerHeight = containerHeight
        self.insetTop = insetTop
        self.insetBottom = insetBottom
        self.visibleMinY = visibleMinY
        self.visibleMaxY = visibleMaxY
    }
}

public enum ScrollBlankKind: String, Codable, Sendable {
    case overshoot
    case unbuilt
    case remount
    case reload
    case sentinelUnbuilt = "sentinel-unbuilt"
}

public enum ScrollBlankCondition {
    public static func isOvershoot(
        contentHeight: CGFloat,
        visibleMinY: CGFloat,
        insetTop: CGFloat
    ) -> Bool {
        contentHeight > 0 && visibleMinY + insetTop >= contentHeight - 1
    }

    public static func kind(
        geometry: ScrollGuardGeometry,
        builtRowCount: Int,
        displayRowCount: Int,
        queuedNoteCount: Int
    ) -> ScrollBlankKind? {
        guard geometry.containerHeight > 0 else { return nil }
        if isOvershoot(
            contentHeight: geometry.contentHeight,
            visibleMinY: geometry.visibleMinY,
            insetTop: geometry.insetTop
        ) {
            return .overshoot
        }
        if builtRowCount == 0, displayRowCount > 0 || queuedNoteCount > 0 {
            return .unbuilt
        }
        return nil
    }
}

public struct ScrollDiagnosticEvent: Codable, Equatable, Sendable {
    public let name: String
    public let oldValue: Double?
    public let newValue: Double?

    public init(name: String, oldValue: Double? = nil, newValue: Double? = nil) {
        self.name = name
        self.oldValue = oldValue
        self.newValue = newValue
    }
}

public struct ScrollDiagnosticEventRing: Sendable {
    private var storage: [ScrollDiagnosticEvent?]
    private var nextIndex = 0
    private(set) public var count = 0

    public init(capacity: Int = 30) {
        storage = Array(repeating: nil, count: max(1, capacity))
    }

    public mutating func append(_ event: ScrollDiagnosticEvent) {
        storage[nextIndex] = event
        nextIndex = (nextIndex + 1) % storage.count
        count = min(count + 1, storage.count)
    }

    public var values: [ScrollDiagnosticEvent] {
        guard count > 0 else { return [] }
        let start = count == storage.count ? nextIndex : 0
        return (0..<count).compactMap { storage[(start + $0) % storage.count] }
    }
}

public struct ScrollDiagnosticGeometry: Codable, Equatable, Sendable {
    public let contentOffsetY: Double
    public let contentHeight: Double
    public let containerHeight: Double
    public let insetTop: Double
    public let insetBottom: Double
    public let visibleRectMinY: Double
    public let visibleRectMaxY: Double

    public init(_ geometry: ScrollGuardGeometry) {
        contentOffsetY = Double(geometry.contentOffsetY)
        contentHeight = Double(geometry.contentHeight)
        containerHeight = Double(geometry.containerHeight)
        insetTop = Double(geometry.insetTop)
        insetBottom = Double(geometry.insetBottom)
        visibleRectMinY = Double(geometry.visibleMinY)
        visibleRectMaxY = Double(geometry.visibleMaxY)
    }
}

public struct ScrollDiagnosticEntry: Codable, Equatable, Sendable {
    public let timestamp: String
    public let appVersion: String
    public let build: String
    public let sessionIDPrefix: String
    public let kind: ScrollBlankKind
    public let geometry: ScrollDiagnosticGeometry
    public let rowsCount: Int
    public let notesCount: Int
    public let isPinnedToBottom: Bool
    public let userHasScrolled: Bool
    public let recentEvents: [ScrollDiagnosticEvent]
    public let lifecycle: [TranscriptLifecycleEvent]
    public let corrections: Int
    public let recovered: Bool
    public let msToRecover: Int

    public init(
        timestamp: String,
        appVersion: String,
        build: String,
        sessionIDPrefix: String,
        kind: ScrollBlankKind,
        geometry: ScrollDiagnosticGeometry,
        rowsCount: Int,
        notesCount: Int,
        isPinnedToBottom: Bool,
        userHasScrolled: Bool,
        recentEvents: [ScrollDiagnosticEvent],
        lifecycle: [TranscriptLifecycleEvent] = [],
        corrections: Int,
        recovered: Bool,
        msToRecover: Int
    ) {
        self.timestamp = timestamp
        self.appVersion = appVersion
        self.build = build
        self.sessionIDPrefix = sessionIDPrefix
        self.kind = kind
        self.geometry = geometry
        self.rowsCount = rowsCount
        self.notesCount = notesCount
        self.isPinnedToBottom = isPinnedToBottom
        self.userHasScrolled = userHasScrolled
        self.recentEvents = recentEvents
        self.lifecycle = lifecycle
        self.corrections = corrections
        self.recovered = recovered
        self.msToRecover = msToRecover
    }
}

public actor ScrollDiagnosticsFileStore {
    public static let maximumLineCount = 200
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    @discardableResult
    public func append(_ entry: ScrollDiagnosticEntry) -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let line = String(decoding: try encoder.encode(entry), as: UTF8.self)
            let existing: [String]
            if let data = try? Data(contentsOf: url) {
                existing = String(decoding: data, as: UTF8.self)
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .map(String.init)
            } else {
                existing = []
            }
            let lines = Self.cappedLines(existing: existing, appending: line)
            let data = Data((lines.joined(separator: "\n") + "\n").utf8)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    public func readLines() -> [String] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    public static func cappedLines(existing: [String], appending line: String) -> [String] {
        Array((existing + [line]).suffix(maximumLineCount))
    }
}

@MainActor
public final class ScrollDiagnosticsRecorder {
    private static let logger = Logger(subsystem: "com.example.cc-controller", category: "scroll-guard")
    private static let timestampFormatter = ISO8601DateFormatter()

    private let fileStore: ScrollDiagnosticsFileStore
    private var sessionIDPrefix: String
    private var ring = ScrollDiagnosticEventRing(capacity: 30)
    private let lifecycleLog: TranscriptLifecycleLog
    private let appVersion: String
    private let build: String

    public init(
        sessionID: String = "",
        fileStore: ScrollDiagnosticsFileStore? = nil,
        appVersion: String? = nil,
        build: String? = nil,
        lifecycleLog: TranscriptLifecycleLog = .shared
    ) {
        let info = Bundle.main.infoDictionary ?? [:]
        self.sessionIDPrefix = String(sessionID.prefix(8))
        self.lifecycleLog = lifecycleLog
        self.fileStore = fileStore ?? ScrollDiagnosticsFileStore(
            url: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("scroll-diagnostics.jsonl")
        )
        self.appVersion = appVersion ?? (info["CFBundleShortVersionString"] as? String ?? "unknown")
        self.build = build ?? (info["CFBundleVersion"] as? String ?? "unknown")
    }

    public func sessionChanged(to sessionID: String) {
        sessionIDPrefix = String(sessionID.prefix(8))
        ring = ScrollDiagnosticEventRing(capacity: 30)
        recordEvent(name: "sessionID", newValue: 1)
    }

    public func recordEvent(name: String, oldValue: Double? = nil, newValue: Double? = nil) {
        ring.append(ScrollDiagnosticEvent(name: name, oldValue: oldValue, newValue: newValue))
    }

    public func record(
        kind: ScrollBlankKind,
        geometry: ScrollGuardGeometry,
        rowsCount: Int,
        notesCount: Int,
        isPinnedToBottom: Bool,
        userHasScrolled: Bool,
        corrections: Int,
        recovered: Bool,
        msToRecover: Int,
        now: Date = Date(),
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        let entry = ScrollDiagnosticEntry(
            timestamp: Self.timestampFormatter.string(from: now),
            appVersion: appVersion,
            build: build,
            sessionIDPrefix: sessionIDPrefix,
            kind: kind,
            geometry: ScrollDiagnosticGeometry(geometry),
            rowsCount: rowsCount,
            notesCount: notesCount,
            isPinnedToBottom: isPinnedToBottom,
            userHasScrolled: userHasScrolled,
            recentEvents: ring.values,
            lifecycle: lifecycleLog.events,
            corrections: corrections,
            recovered: recovered,
            msToRecover: msToRecover
        )
        let kindCode: Int
        switch kind {
        case .overshoot: kindCode = 1
        case .unbuilt: kindCode = 2
        case .remount: kindCode = 3
        case .reload: kindCode = 4
        case .sentinelUnbuilt: kindCode = 5
        }
        Self.logger.notice(
            "scroll guard kind=\(kindCode, privacy: .public) offset=\(entry.geometry.contentOffsetY, privacy: .public) content=\(entry.geometry.contentHeight, privacy: .public) container=\(entry.geometry.containerHeight, privacy: .public) corrections=\(corrections, privacy: .public) recovered=\(recovered ? 1 : 0, privacy: .public) ms=\(msToRecover, privacy: .public)"
        )
        let fileStore = self.fileStore
        Task {
            let written = await fileStore.append(entry)
            completion?(written)
        }
    }

    public func recordLifecycleTrigger(
        _ trigger: TranscriptLifecycleTrigger,
        geometry: ScrollGuardGeometry = ScrollGuardGeometry(
            contentOffsetY: 0,
            contentHeight: 0,
            containerHeight: 0,
            insetTop: 0,
            insetBottom: 0,
            visibleMinY: 0,
            visibleMaxY: 0
        ),
        rowsCount: Int = 0,
        notesCount: Int = 0,
        isPinnedToBottom: Bool = false,
        userHasScrolled: Bool = false,
        now: Date = Date(),
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        let entry = ScrollDiagnosticEntry(
            timestamp: Self.timestampFormatter.string(from: now),
            appVersion: appVersion,
            build: build,
            sessionIDPrefix: TranscriptLifecycleLog.sessionPrefix(trigger.sessionID) ?? "",
            kind: trigger.kind,
            geometry: ScrollDiagnosticGeometry(geometry),
            rowsCount: rowsCount,
            notesCount: notesCount,
            isPinnedToBottom: isPinnedToBottom,
            userHasScrolled: userHasScrolled,
            recentEvents: ring.values,
            lifecycle: lifecycleLog.events,
            corrections: 0,
            recovered: false,
            msToRecover: 0
        )
        let fileStore = self.fileStore
        Task {
            let written = await fileStore.append(entry)
            completion?(written)
        }
    }
}
