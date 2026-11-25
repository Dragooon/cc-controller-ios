import CCKit
import SwiftUI

/// Settings → Voice: the reply voice and the recordings archive.
struct VoiceSettingsSection: View {
    @AppStorage("voiceModeVoice") private var voice = ""
    @AppStorage(VoiceSettings.speedKey) private var speed = 0.0
    @State private var confirmingDelete = false
    @State private var bytes: Int64 = 0

    /// Kokoro's voices on the hosts today. The host's own default is used when none is picked.
    private static let voices: [(id: String, label: String)] = [
        ("af_heart", "Heart (US)"), ("af_bella", "Bella (US)"), ("af_nicole", "Nicole (US)"), ("af_sarah", "Sarah (US)"),
        ("am_michael", "Michael (US)"), ("am_adam", "Adam (US)"), ("bf_emma", "Emma (UK)"), ("bm_george", "George (UK)"),
        ("bm_lewis", "Lewis (UK)"),
    ]

    var body: some View {
        let archive = VoiceCenter.shared.archive
        Section("Voice") {
            Picker("Reply voice", selection: $voice) {
                Text("Host default").tag("")
                ForEach(Self.voices, id: \.id) { item in
                    Text(item.label).tag(item.id)
                }
            }
            .accessibilityIdentifier("settings-voice")
            Picker("Speaking speed", selection: $speed) {
                ForEach(VoiceSettings.speedChoices, id: \.self) { choice in
                    Text(VoiceSettings.speedLabel(choice)).tag(choice)
                }
            }
            .accessibilityIdentifier("settings-voice-speed")
            LabeledContent("Recordings", value: "\(archive.recordings.count) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                .accessibilityIdentifier("settings-voice-recordings")
            if !archive.recordings.isEmpty {
                ShareLink(items: archive.allFileURLs()) {
                    Label("Export recordings", systemImage: "square.and.arrow.up")
                }
                Button("Delete all recordings", role: .destructive) { confirmingDelete = true }
                    .confirmationDialog("Delete every voice recording on this iPhone?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                        Button("Delete all", role: .destructive) {
                            archive.deleteAll()
                            bytes = 0
                        }
                        Button("Cancel", role: .cancel) {}
                    }
            }
        }
        .task(id: archive.recordings.count) { bytes = archive.totalBytes() }
    }
}
