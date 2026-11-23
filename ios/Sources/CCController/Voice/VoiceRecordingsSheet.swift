import AVFoundation
import CCKit
import SwiftUI

/// Reads a message aloud: the message's markdown and an id to track which one is playing.
struct ReadAloudAction: Sendable {
    let read: @MainActor @Sendable (_ markdown: String, _ id: String) -> Void
}

/// Lets a sent message find the voice clips it was made from.
struct VoiceRecordingsAccess: Sendable {
    let count: @MainActor @Sendable (_ turnText: String) -> Int
    let open: @MainActor @Sendable (_ turnText: String) -> Void
}

extension EnvironmentValues {
    @Entry var readAloud: ReadAloudAction? = nil
    @Entry var voiceRecordings: VoiceRecordingsAccess? = nil
}

/// Adds Read aloud and Copy reply to an assistant reply's long-press menu, when the host can speak.
struct ReadAloudMenu: ViewModifier {
    let text: String
    let id: String
    @Environment(\.readAloud) private var readAloud

    func body(content: Content) -> some View {
        if let readAloud, !text.isEmpty {
            content.contextMenu {
                if VoiceCenter.shared.readingID == id {
                    Button { VoiceCenter.shared.stopReading() } label: {
                        Label("Stop reading", systemImage: "stop.fill")
                    }
                } else {
                    Button { readAloud.read(text, id) } label: {
                        Label("Read aloud", systemImage: "speaker.wave.2")
                    }
                }
                Button { UIPasteboard.general.string = text } label: {
                    Label("Copy reply", systemImage: "doc.on.doc")
                }
            }
        } else {
            content
        }
    }
}

/// The mic mark under a message you spoke, opening its clips.
struct VoiceRecordingsMark: View {
    let turnText: String
    @Environment(\.voiceRecordings) private var voiceRecordings

    var body: some View {
        if let voiceRecordings {
            let count = voiceRecordings.count(turnText)
            if count > 0 {
                Button { voiceRecordings.open(turnText) } label: {
                    Label(count == 1 ? "Spoken" : "Spoken · \(count) clips", systemImage: "mic.fill")
                        .font(.caption)
                        .foregroundStyle(.ccSecondary)
                        .padding(.trailing, 6)
                }
                .buttonStyle(.ccPressable)
                .accessibilityIdentifier("voice-recordings-mark")
            }
        }
    }
}

/// The clips behind a message (or a whole session): play the original, or transcribe it again.
struct VoiceRecordingsSheet: View {
    let title: String
    let recordings: [VoiceRecording]
    let archive: VoiceRecordingArchive
    let store: AppStore
    let close: () -> Void

    @State private var player: AVAudioPlayer?
    @State private var playingID: String?
    @State private var retranscribing: Set<String> = []
    @State private var retranscribed: [String: String] = [:]

    var body: some View {
        NavigationStack {
            List(recordings) { recording in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(recording.createdAt.formatted(date: .abbreviated, time: .standard))
                            .font(.footnote)
                            .foregroundStyle(.ccSecondary)
                        Text(String(format: "%.1f s", Double(recording.durationMs) / 1_000))
                            .font(.footnote)
                            .foregroundStyle(.ccTertiary)
                        if recording.echo {
                            Text("Echo, not sent")
                                .font(.footnote)
                                .foregroundStyle(.ccAmberText)
                        }
                        Spacer()
                    }
                    Text(recording.transcript?.isEmpty == false ? recording.transcript! : "No speech heard")
                        .font(.body)
                        .foregroundStyle(.ccLabel)
                    if let again = retranscribed[recording.id] {
                        Text("Again: \(again)")
                            .font(.body)
                            .foregroundStyle(.ccBlue)
                    }
                    HStack(spacing: 16) {
                        Button(playingID == recording.id ? "Stop" : "Play") { togglePlay(recording) }
                        Button(retranscribing.contains(recording.id) ? "Transcribing…" : "Transcribe again") { retranscribe(recording) }
                            .disabled(retranscribing.contains(recording.id))
                        if let model = recording.model {
                            Text(model.split(separator: "/").last.map(String.init) ?? model)
                                .font(.caption)
                                .foregroundStyle(.ccTertiary)
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.callout.weight(.semibold))
                }
                .padding(.vertical, 4)
                .accessibilityIdentifier("voice-recording-\(recording.id)")
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: close)
                }
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(items: recordings.map(archive.fileURL(for:))) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Export clips")
                }
            }
        }
        .onDisappear { player?.stop() }
    }

    private func togglePlay(_ recording: VoiceRecording) {
        if playingID == recording.id {
            player?.stop()
            playingID = nil
            return
        }
        guard VoiceCenter.shared.active == nil else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        player = try? AVAudioPlayer(contentsOf: archive.fileURL(for: recording))
        player?.play()
        playingID = player == nil ? nil : recording.id
    }

    private func retranscribe(_ recording: VoiceRecording) {
        retranscribing.insert(recording.id)
        Task {
            defer { retranscribing.remove(recording.id) }
            guard let audio = try? Data(contentsOf: archive.fileURL(for: recording)) else { return }
            if let result = try? await store.transcribeVoice(audio: audio, filename: recording.fileName, mimeType: recording.mimeType) {
                retranscribed[recording.id] = result.text.isEmpty ? "No speech heard" : result.text
            }
        }
    }
}
