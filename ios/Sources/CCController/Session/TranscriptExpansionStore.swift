import SwiftUI

@MainActor @Observable
final class TranscriptExpansionStore {
    private var expanded: [String: Bool] = [:]
    @ObservationIgnored var onChange: ((String) -> Void)?
    @ObservationIgnored var onHeightChange: ((String) -> Void)?

    func value(for key: String) -> Bool? { expanded[key] }

    func set(_ value: Bool, for key: String) {
        expanded[key] = value
        onChange?(key)
    }

    /// A row whose content resized on its own, like an image that finished loading, asks to be
    /// measured again. Unlike an expansion, it keeps the transcript's current anchor.
    func heightChanged(for key: String) {
        onHeightChange?(key)
    }
}

extension EnvironmentValues {
    @Entry var transcriptExpansion: TranscriptExpansionStore? = nil
}
