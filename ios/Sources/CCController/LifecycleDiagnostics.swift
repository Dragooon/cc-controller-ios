import CCKit
import SwiftUI

@MainActor
func recordLifecycleEvent(
    name: String,
    sessionID: String? = nil,
    detail: String? = nil,
    input: TranscriptLifecycleTriggerInput? = nil
) {
    TranscriptLifecycleLog.shared.record(name: name, sessionID: sessionID, detail: detail)
    guard let input else { return }
    let triggers = TranscriptLifecycleDiagnostics.shared.ingest(input)
    guard !triggers.isEmpty else { return }
    let recorder = ScrollDiagnosticsRecorder(sessionID: sessionID ?? "")
    for trigger in triggers {
        recorder.recordLifecycleTrigger(trigger)
    }
}
