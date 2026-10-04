import Foundation

public struct TranscriptChangeSet: Sendable, Equatable {
    public var inserted: [TranscriptEntry]
    public var updated: [TranscriptEntry]
    public var updatedIDs: [String]
    public init(inserted: [TranscriptEntry] = [], updated: [TranscriptEntry] = [], updatedIDs: [String] = []) {
        self.inserted = inserted
        self.updated = updated
        self.updatedIDs = updatedIDs
    }

    public var changed: [TranscriptEntry] { inserted + updated }
}

public struct TranscriptStore: Sendable, Equatable {
    public private(set) var entries: [TranscriptEntry]
    private var keys: [String]
    private var identityIndex: [String: Int]
    private var protectedReplacementKeys: Set<String>

    public init(entries: [TranscriptEntry] = []) {
        self.entries = entries
        let initialKeys = entries.map { Self.identityKey(for: $0) }
        self.keys = initialKeys
        var identityIndex: [String: Int] = [:]
        for (index, key) in initialKeys.enumerated() {
            if identityIndex[key] == nil { identityIndex[key] = index }
        }
        self.identityIndex = identityIndex
        self.protectedReplacementKeys = []
    }

    @discardableResult
    public mutating func merge(_ incoming: [TranscriptEntry], replace: Bool = false, appendNewEntries: Bool = false) -> TranscriptChangeSet {
        var inserted: [TranscriptEntry] = []
        var updated: [TranscriptEntry] = []
        var updatedIDs: [String] = []
        for entry in incoming {
            let key = identityKey(for: entry)
            if let index = identityIndex[key] {
                guard shouldAccept(entry, over: entries[index], key: key, replacement: replace) else { continue }
                entries[index] = entry
                if replace { protectedReplacementKeys.insert(key) }
                updated.append(entry)
                updatedIDs.append(entry.id ?? key)
                continue
            }
            let index = appendNewEntries ? entries.count : insertionIndex(for: entry)
            entries.insert(entry, at: index)
            keys.insert(key, at: index)
            for shiftedIndex in index..<keys.count { identityIndex[keys[shiftedIndex]] = shiftedIndex }
            inserted.append(entry)
        }
        return TranscriptChangeSet(inserted: inserted, updated: updated, updatedIDs: updatedIDs)
    }

    public mutating func replaceAll(with entries: [TranscriptEntry]) -> TranscriptChangeSet {
        self.entries = []
        self.keys = []
        self.identityIndex = [:]
        return merge(entries)
    }

    public func identityKey(for entry: TranscriptEntry) -> String {
        Self.identityKey(for: entry)
    }

    public func containsIdentity(of entry: TranscriptEntry) -> Bool {
        identityIndex[Self.identityKey(for: entry)] != nil
    }

    public func isBeforeFirst(_ entry: TranscriptEntry) -> Bool {
        !entries.isEmpty && insertionIndex(for: entry) == 0
    }

    private static func identityKey(for entry: TranscriptEntry) -> String {
        if let id = entry.id { return "id|\(id)" }
        if (entry.kind == "tool" || entry.kind == "subagent" || entry.kind == "subagent_result"), let toolUseId = entry.toolUseId {
            return "\(entry.kind)|\(toolUseId)"
        }
        let timestamp = entry.ts.map(CCDateCoding.format) ?? ""
        return "\(timestamp)|\(entry.kind)|\(entry.text ?? "")"
    }

    private func shouldAccept(_ incoming: TranscriptEntry, over current: TranscriptEntry, key: String, replacement: Bool) -> Bool {
        if let currentRev = current.rev {
            guard let incomingRev = incoming.rev else { return false }
            return incomingRev > currentRev
        }
        if incoming.rev != nil { return true }
        if protectedReplacementKeys.contains(key) && !replacement { return false }
        return incoming != current
    }

    private func insertionIndex(for entry: TranscriptEntry) -> Int {
        guard let timestamp = entry.ts else { return entries.count }
        for (index, existing) in entries.enumerated() {
            guard let existingTimestamp = existing.ts else { continue }
            if timestamp < existingTimestamp { return index }
        }
        return entries.count
    }
}
