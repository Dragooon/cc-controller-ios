import CCKit
import SwiftUI

@MainActor
func recordLifecycleEvent(
    name: String,
    sessionID: String? = nil,
    detail: String? = nil,
    input: TranscriptLifecycleTriggerInput? = nil,
    recorder: ScrollDiagnosticsRecorder? = nil,
    geometry: ScrollGuardGeometry? = nil,
    rowsCount: Int = 0,
    notesCount: Int = 0,
    isPinnedToBottom: Bool = false,
    userHasScrolled: Bool = false
) {
    TranscriptLifecycleLog.shared.record(name: name, sessionID: sessionID, detail: detail)
    guard let input else { return }
    let triggers = TranscriptLifecycleDiagnostics.shared.ingest(input)
    writeLifecycleTriggers(
        triggers,
        sessionID: sessionID,
        recorder: recorder,
        geometry: geometry,
        rowsCount: rowsCount,
        notesCount: notesCount,
        isPinnedToBottom: isPinnedToBottom,
        userHasScrolled: userHasScrolled
    )
}

@MainActor
func writeLifecycleTriggers(
    _ triggers: [TranscriptLifecycleTrigger],
    sessionID: String?,
    recorder: ScrollDiagnosticsRecorder?,
    geometry: ScrollGuardGeometry?,
    rowsCount: Int,
    notesCount: Int,
    isPinnedToBottom: Bool,
    userHasScrolled: Bool
) {
    guard !triggers.isEmpty else { return }
    let writer = recorder ?? ScrollDiagnosticsRecorder(sessionID: sessionID ?? "")
    for trigger in triggers {
        writer.recordLifecycleTrigger(
            trigger,
            geometry: geometry ?? ScrollGuardGeometry(
                contentOffsetY: 0,
                contentHeight: 0,
                containerHeight: 0,
                insetTop: 0,
                insetBottom: 0,
                visibleMinY: 0,
                visibleMaxY: 0
            ),
            rowsCount: rowsCount,
            notesCount: notesCount,
            isPinnedToBottom: isPinnedToBottom,
            userHasScrolled: userHasScrolled
        )
    }
}
