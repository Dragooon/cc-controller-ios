import Foundation

/// A Claude model id split into the parts the picker sorts and names by.
struct ClaudeModelVersion: Equatable {
    /// "fable", "opus", "sonnet" or "haiku".
    let family: String
    let major: Int
    /// Nil for an id with one number, such as claude-sonnet-5.
    let minor: Int?
    /// The id ends in "[1m]".
    let hasLongContextSuffix: Bool

    /// Claude Code runs these with the 1M window whether or not the id carries "[1m]": Fable models, Sonnet 5
    /// and later, Haiku 5.5 and later, Opus 4.7 and later. For them the suffixed id is the same model.
    var runsLongContextWithoutSuffix: Bool {
        let minorNumber = minor ?? 0
        switch family {
        case "fable": return true
        case "sonnet": return major >= 5
        case "haiku": return major > 5 || (major == 5 && minorNumber >= 5)
        case "opus": return major > 4 || (major == 4 && minorNumber >= 7)
        default: return false
        }
    }

    var name: String {
        let familyName = family.prefix(1).uppercased() + family.dropFirst()
        let number = minor.map { "\(major).\($0)" } ?? "\(major)"
        return "\(familyName) \(number)"
    }
}

/// The order model families are listed in, most capable first.
private let claudeModelFamilies = ["fable", "opus", "sonnet", "haiku"]

private let claudeModelVersionPattern = try? NSRegularExpression(
    pattern: #"^(?:.*anthropic\.)?claude-(fable|opus|sonnet|haiku)-(\d{1,2})(?:-(\d{1,2}))?(?:-\d{8})?(\[1m\])?$"#,
    options: [.caseInsensitive]
)

func claudeModelVersion(_ id: String) -> ClaudeModelVersion? {
    let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
    let wholeRange = NSRange(trimmed.startIndex..., in: trimmed)
    guard let match = claudeModelVersionPattern?.firstMatch(in: trimmed, options: [], range: wholeRange) else { return nil }
    func group(_ index: Int) -> String? {
        guard let range = Range(match.range(at: index), in: trimmed) else { return nil }
        return String(trimmed[range])
    }
    guard let family = group(1)?.lowercased(), let major = group(2).flatMap(Int.init) else { return nil }
    return ClaudeModelVersion(
        family: family,
        major: major,
        minor: group(3).flatMap(Int.init),
        hasLongContextSuffix: group(4) != nil
    )
}

/// The family a short name such as "opus" or "opus[1m]" stands for. Nil for anything else.
private func claudeModelAliasFamily(_ id: String) -> String? {
    var value = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if value.hasSuffix("[1m]") { value = String(value.dropLast(4)) }
    return claudeModelFamilies.contains(value) ? value : nil
}

private func isDefaultModelID(_ id: String) -> Bool {
    id.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("default") == .orderedSame
}

/// Whether a model name is a model at all. Claude Code writes notices of its own, such as the usage-limit
/// line, under the name "<synthetic>".
public func isRealModelID(_ id: String?) -> Bool {
    let value = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return !value.isEmpty && !value.hasPrefix("<")
}

/// The models to offer, one entry for each model.
///
/// A controller lists Claude Code's short names ("opus"), exact versions ("claude-opus-5-5") and "[1m]"
/// variants side by side. The short name is left out when an exact version of its family is listed, and a
/// "[1m]" variant when it is the same model as the plain id. Order: Default, then Fable, Opus, Sonnet, Haiku
/// with the newest version first, then everything else as the controller ordered it.
///
/// - Parameter defaultModelLabel: what "Default" launches, shown as "Default (Opus 5.5)".
public func pickerModels(_ models: [ModelOption], defaultModelLabel: String? = nil) -> [ModelOption] {
    var defaults: [ModelOption] = []
    var versioned: [(model: ModelOption, version: ClaudeModelVersion, position: Int)] = []
    var aliases: [(model: ModelOption, family: String, hasSuffix: Bool)] = []
    var others: [ModelOption] = []

    for (position, model) in models.enumerated() {
        if isDefaultModelID(model.id) {
            defaults.append(model)
        } else if let version = claudeModelVersion(model.id) {
            versioned.append((model, version, position))
        } else if let family = claudeModelAliasFamily(model.id) {
            aliases.append((model, family, model.id.lowercased().hasSuffix("[1m]")))
        } else {
            others.append(model)
        }
    }

    func isSameRelease(_ left: ClaudeModelVersion, _ right: ClaudeModelVersion) -> Bool {
        left.family == right.family && left.major == right.major && (left.minor ?? 0) == (right.minor ?? 0)
    }

    // A "[1m]" id that is the same model as a listed plain id goes.
    let withoutSameModelVariants = versioned.filter { entry in
        guard entry.version.hasLongContextSuffix, entry.version.runsLongContextWithoutSuffix else { return true }
        return !versioned.contains { other in
            !other.version.hasLongContextSuffix && isSameRelease(other.version, entry.version)
        }
    }
    // A dated id and its plain id are the same entry too: the first one listed stays.
    var kept: [(model: ModelOption, version: ClaudeModelVersion, position: Int)] = []
    for entry in withoutSameModelVariants {
        let isRepeat = kept.contains { other in
            isSameRelease(other.version, entry.version) && other.version.hasLongContextSuffix == entry.version.hasLongContextSuffix
        }
        if !isRepeat { kept.append(entry) }
    }
    kept.sort { left, right in
        let leftFamily = claudeModelFamilies.firstIndex(of: left.version.family) ?? claudeModelFamilies.count
        let rightFamily = claudeModelFamilies.firstIndex(of: right.version.family) ?? claudeModelFamilies.count
        if leftFamily != rightFamily { return leftFamily < rightFamily }
        if left.version.major != right.version.major { return left.version.major > right.version.major }
        let leftMinor = left.version.minor ?? 0
        let rightMinor = right.version.minor ?? 0
        if leftMinor != rightMinor { return leftMinor > rightMinor }
        if left.version.hasLongContextSuffix != right.version.hasLongContextSuffix { return !left.version.hasLongContextSuffix }
        return left.position < right.position
    }

    let familiesWithAVersion = Set(kept.map(\.version.family))
    let keptAliases = aliases.filter { entry in
        guard !familiesWithAVersion.contains(entry.family) else { return false }
        // "opus[1m]" beside "opus" is the same choice.
        if entry.hasSuffix { return !aliases.contains { $0.family == entry.family && !$0.hasSuffix } }
        return true
    }

    func hasOwnLabel(_ model: ModelOption) -> Bool {
        let label = model.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return !label.isEmpty && label.caseInsensitiveCompare(model.id) != .orderedSame
    }

    var result: [ModelOption] = []
    for var model in defaults {
        if let defaultModelLabel, !defaultModelLabel.isEmpty, !isDefaultModelID(defaultModelLabel) {
            model.label = "Default (\(defaultModelLabel))"
        } else if !hasOwnLabel(model) {
            model.label = "Default"
        }
        result.append(model)
    }
    for entry in kept {
        var model = entry.model
        if !hasOwnLabel(model) {
            // Only where the plain id runs a shorter window does "[1m]" make a different model.
            let isLongContextVariant = entry.version.hasLongContextSuffix && !entry.version.runsLongContextWithoutSuffix
            model.label = isLongContextVariant ? "\(entry.version.name) · 1M" : entry.version.name
        }
        result.append(model)
    }
    for entry in keptAliases {
        var model = entry.model
        if !hasOwnLabel(model) {
            model.label = entry.family.prefix(1).uppercased() + entry.family.dropFirst()
        }
        result.append(model)
    }
    result.append(contentsOf: others)
    return result
}

/// Whether two ids name the same model: the same release whatever the "[1m]" or date, or a short name and a
/// release of its family.
public func modelIDsNameTheSameModel(_ left: String, _ right: String) -> Bool {
    if left.caseInsensitiveCompare(right) == .orderedSame { return true }
    let leftVersion = claudeModelVersion(left)
    let rightVersion = claudeModelVersion(right)
    if let leftVersion, let rightVersion {
        return leftVersion.family == rightVersion.family
            && leftVersion.major == rightVersion.major
            && (leftVersion.minor ?? 0) == (rightVersion.minor ?? 0)
    }
    if let leftVersion, let rightFamily = claudeModelAliasFamily(right) { return leftVersion.family == rightFamily }
    if let rightVersion, let leftFamily = claudeModelAliasFamily(left) { return rightVersion.family == leftFamily }
    return false
}

/// The entry of the offered list a session is on, to tick. A model picked for the session wins, since the
/// transcript shows the old one until the next turn. A short name that isn't listed falls through to the model
/// the session reports.
public func pickerCurrentModelID(models: [ModelOption], picked: String?, running: String?) -> String? {
    for candidate in [picked, running] {
        guard let candidate, isRealModelID(candidate) else { continue }
        if let exact = models.first(where: { $0.id.caseInsensitiveCompare(candidate) == .orderedSame }) {
            return exact.id
        }
        if let candidateVersion = claudeModelVersion(candidate) {
            let sameRelease = models.filter { model in
                guard let version = claudeModelVersion(model.id) else { return false }
                return version.family == candidateVersion.family
                    && version.major == candidateVersion.major
                    && (version.minor ?? 0) == (candidateVersion.minor ?? 0)
            }
            let sameWindow = sameRelease.first { claudeModelVersion($0.id)?.hasLongContextSuffix == candidateVersion.hasLongContextSuffix }
            if let match = sameWindow ?? sameRelease.first { return match.id }
        }
        if let match = matchingCommandModelID(options: models, usageModel: candidate) { return match }
    }
    return nil
}

/// The model to name on a session's chip: the one it reports, unless another was picked and waits for the next
/// turn. Names that aren't models (see `isRealModelID`) are skipped.
public func shownSessionModelID(picked: String?, usage: String?, transcript: String?) -> String? {
    let running = [usage, transcript].compactMap { $0 }.first(where: { isRealModelID($0) })
    guard let picked, isRealModelID(picked), !isDefaultModelID(picked) else { return running }
    guard let running else { return picked }
    return modelIDsNameTheSameModel(picked, running) ? running : picked
}
