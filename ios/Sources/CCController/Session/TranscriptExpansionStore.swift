import SwiftUI

@MainActor @Observable
final class TranscriptExpansionStore {
    private var expanded: [String: Bool] = [:]
    @ObservationIgnored var onChange: ((String) -> Void)?

    func value(for key: String) -> Bool? { expanded[key] }

    func set(_ value: Bool, for key: String) {
        expanded[key] = value
        onChange?(key)
    }
}

extension EnvironmentValues {
    @Entry var transcriptExpansion: TranscriptExpansionStore? = nil
}
