import ActivityKit
import AVFoundation
import CCKit
import Foundation
import MediaPlayer
import Observation
import UIKit
import os

private let voiceLiveActivityLogger = Logger(subsystem: "cc-controller", category: "voice-live-activity")

/// ActivityKit's update and end run off the main actor, and Activity isn't Sendable, so the calls go through this box
/// from a detached task. Each activity is only touched by one call at a time from voice mode.
private struct LiveActivityHandle: @unchecked Sendable {
    let activity: Activity<VoiceActivityAttributes>

    func update(_ state: VoiceActivityAttributes.ContentState) {
        Task.detached { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    func end() {
        Task.detached { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}

/// One hands-free conversation with one session. The phone listens all the time; each pause ends an utterance, the
/// host transcribes it, and a finished thought is sent as your message with the voice mark. Every text block the
/// agent writes is spoken back; tool calls never are. Nothing you say is treated as a command.
@MainActor @Observable
final class VoiceModeController {
    enum Phase: Equatable {
        case starting
        case listening
        case hearing
        case sending
        case working
        case speaking
        case paused
        case muted
        case failed(String)

        var label: String {
            switch self {
            case .starting: "Starting"
            case .listening: "Listening"
            case .hearing: "Hearing you"
            case .sending: "Sending"
            case .working: "Working"
            case .speaking: "Speaking"
            case .paused: "Paused"
            case .muted: "Mic off"
            case .failed: "Voice stopped"
            }
        }

        /// SF Symbol for the Live Activity.
        var symbol: String {
            switch self {
            case .starting, .listening: "waveform"
            case .hearing: "mic.fill"
            case .sending, .working: "ellipsis"
            case .speaking: "speaker.wave.2.fill"
            case .paused: "pause.fill"
            case .muted: "mic.slash.fill"
            case .failed: "exclamationmark.triangle.fill"
            }
        }
    }

    let sessionID: String
    let controllerID: ControllerID
    let sessionName: String
    let store: AppStore

    private(set) var phase: Phase = .starting
    /// Your turn so far, as the host heard it.
    private(set) var heardText = ""
    /// The sentence being spoken.
    private(set) var speakingText = ""
    private(set) var notice: String?
    /// What the agent last put on the screen, and everything it showed while voice mode was on.
    private(set) var stage: StageEntry?
    private(set) var stageHistory: [StageEntry] = []
    private(set) var isPaused = false
    /// The mic is off but replies keep playing (an AirPods press, or the strip's Mute).
    private(set) var isMicMuted = false
    private(set) var canReplay = false
    /// The stage fills the screen, or folds to the strip over the chat. Kept here so it survives the session
    /// screen being rebuilt (a turn ending, the sidebar, coming back to the session).
    var stageExpanded = true

    @ObservationIgnored private let engine = VoiceAudioEngine()
    @ObservationIgnored private let archive: VoiceRecordingArchive
    /// Read at each decision, so a change in Settings applies to the next turn.
    private var policy: VoiceTurnPolicy { VoiceTurnPolicy(pauseBeforeSend: VoiceSettings.pause) }
    /// When the phone last stopped hearing you: the pause before a turn is sent counts from here.
    @ObservationIgnored private var speechEndedAt: Date?
    @ObservationIgnored private var tracker = VoiceReplyTracker(baseline: [])
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    // Your turn.
    @ObservationIgnored private var turnUtterances: [(id: String, text: String)] = []
    @ObservationIgnored private var turnStartedAt: Date?
    @ObservationIgnored private var transcribing = 0
    @ObservationIgnored private var userSpeaking = false
    @ObservationIgnored private var holdTask: Task<Void, Never>?

    // The agent's turn.
    @ObservationIgnored private var sentenceQueue: [String] = []
    @ObservationIgnored private var speakingTask: Task<Void, Never>?
    @ObservationIgnored private var fetches: [String: Task<Data?, Never>] = [:]
    @ObservationIgnored private var audioCache: [String: Data] = [:]
    @ObservationIgnored private var currentReply: [String] = []
    @ObservationIgnored private var lastReply: [String] = []
    @ObservationIgnored private var previousSentence = ""
    @ObservationIgnored private var awaitingReply = false
    @ObservationIgnored private var turnEndPending = false
    @ObservationIgnored private var lastSoundAt = Date()
    @ObservationIgnored private var transcriptSignature = ""
    @ObservationIgnored private var knownApprovalIDs: Set<String> = []
    @ObservationIgnored private var remoteTargets: [(MPRemoteCommand, Any)] = []
    @ObservationIgnored private var muteGestureObserver: NSObjectProtocol?
    @ObservationIgnored private var liveActivity: Activity<VoiceActivityAttributes>?
    @ObservationIgnored private var liveActivityState: VoiceActivityAttributes.ContentState?

    init(store: AppStore, controllerID: ControllerID, sessionID: String, sessionName: String, archive: VoiceRecordingArchive) {
        self.store = store
        self.controllerID = controllerID
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.archive = archive
    }

    var isSpeaking: Bool { engine.isReplyPlaying || speakingTask != nil }

    // MARK: Start and stop

    /// UI tests run without a microphone: the engine only plays, and the strip offers a button that feeds a silent
    /// clip through the same path a real utterance takes.
    static var usesTestAudio: Bool { ProcessInfo.processInfo.arguments.contains("-CCVoiceTestAudio") }

    func start() async {
        if !Self.usesTestAudio {
            guard await AVAudioApplication.requestRecordPermission() else {
                phase = .failed("Code needs the microphone for voice mode. Turn it on in Settings, then try again.")
                return
            }
        }
        let entries = store.openSession(sessionID)?.entries ?? []
        tracker = VoiceReplyTracker(baseline: entries)
        stage = entries.reversed().lazy.compactMap(\.stage).first(where: \.isDone)
        knownApprovalIDs = Set((store.sessions[sessionID]?.pending ?? []).compactMap(\.requestId))
        do {
            try await engine.start(listen: !Self.usesTestAudio)
        } catch {
            phase = .failed("The microphone couldn't start: \(error.localizedDescription)")
            return
        }
        UIApplication.shared.isIdleTimerDisabled = true
        setUpRemoteCommands()
        startLiveActivity()
        phase = .listening
        updateNowPlaying()
        let events = engine.events
        tasks.append(Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.handle(event)
            }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(250))
            }
        })
        await store.setSessionVoice(sessionID: sessionID, on: true)
    }

    func stop() {
        for task in tasks { task.cancel() }
        tasks = []
        holdTask?.cancel()
        speakingTask?.cancel()
        speakingTask = nil
        for fetch in fetches.values { fetch.cancel() }
        fetches = [:]
        engine.stop()
        tearDownRemoteCommands()
        endLiveActivity()
        if AVAudioApplication.shared.isInputMuted {
            try? AVAudioApplication.shared.setInputMuted(false)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        UIApplication.shared.isIdleTimerDisabled = false
        let store = store
        let sessionID = sessionID
        Task { await store.setSessionVoice(sessionID: sessionID, on: false) }
    }

    // MARK: Controls

    /// Play/pause: pauses the reply where it is and mutes the mic, or resumes both.
    func togglePause() { setPaused(!isPaused) }

    func setPaused(_ paused: Bool) {
        guard paused != isPaused, phase != .starting else { return }
        isPaused = paused
        syncMicMute()
        if paused {
            holdTask?.cancel()
            engine.pauseReplies()
            engine.play(.muted)
            phase = .paused
        } else {
            engine.resumeReplies()
            engine.play(.listening)
            refreshPhase()
            evaluateTurn()
        }
        updateNowPlaying()
    }

    func toggleMicMute() { setMicMuted(!isMicMuted) }

    /// Mute: the mic stops listening and the reply carries on. Pause stops both.
    func setMicMuted(_ muted: Bool) {
        guard muted != isMicMuted, phase != .starting else { return }
        isMicMuted = muted
        syncMicMute()
        if muted { holdTask?.cancel() }
        engine.play(muted ? .muted : .listening)
        refreshPhase()
        if !muted { evaluateTurn() }
    }

    /// The tap ignores the mic while paused or muted, and the system's mic mute (what an AirPods press toggles and
    /// the green/orange indicator shows) matches.
    private func syncMicMute() {
        let off = isPaused || isMicMuted
        engine.setMuted(off)
        if AVAudioApplication.shared.isInputMuted != off {
            try? AVAudioApplication.shared.setInputMuted(off)
        }
    }

    /// The big target: cuts a reply that's playing, or sends the turn you've started straight away.
    func tap() {
        if isPaused { setPaused(false); return }
        if isSpeaking {
            interruptReply()
        } else if !turnUtterances.isEmpty, transcribing == 0 {
            sendTurn()
        }
    }

    /// Plays the last reply again from the cached audio, without asking the agent.
    func replay() {
        let sentences = currentReply.isEmpty ? lastReply : currentReply
        guard !sentences.isEmpty else { return }
        interruptReply()
        if isPaused { setPaused(false) }
        sentenceQueue = sentences
        startSpeaking()
    }

    /// UI tests: a second of silence, as if you'd just spoken; the fixture decides what the host "heard".
    func injectTestUtterance() {
        let id = UUID().uuidString.lowercased()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("utterance-\(id).wav")
        let rate = 16_000
        var data = Data()
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let samples = rate
        data.append(contentsOf: Array("RIFF".utf8)); append32(UInt32(36 + samples * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append32(16); append16(1); append16(1)
        append32(UInt32(rate)); append32(UInt32(rate * 2)); append16(2); append16(16)
        data.append(contentsOf: Array("data".utf8)); append32(UInt32(samples * 2))
        data.append(Data(count: samples * 2))
        guard (try? data.write(to: url)) != nil else { return }
        receive(VoiceAudioClip(id: id, url: url, durationMs: 1_000, overlappedReply: engine.isReplyPlaying, mimeType: "audio/wav"))
    }

    /// Brings an earlier stage item back.
    func show(_ entry: StageEntry) { stage = entry }

    /// Reads a message aloud within the conversation.
    func readAloud(_ markdown: String) {
        let sentences = SpeakableText.sentences(SpeakableText.speakable(markdown))
        guard !sentences.isEmpty else { return }
        interruptReply()
        sentenceQueue = sentences
        startSpeaking()
    }

    // MARK: Mic events

    private func handle(_ event: VoiceAudioEvent) {
        switch event {
        case .speechStarted:
            userSpeaking = true
            holdTask?.cancel()
            if engine.isReplyPlaying {
                engine.duckReplies(true)
            } else if phase == .listening || phase == .working {
                phase = .hearing
            }
        case .speechDiscarded:
            userSpeaking = false
            engine.duckReplies(false)
            refreshPhase()
            evaluateTurn()
        case .utterance(let clip):
            userSpeaking = false
            speechEndedAt = Date()
            receive(clip)
        case .failed(let message):
            notice = message
            engine.play(.dropped)
            setPaused(true)
        }
    }

    private func receive(_ clip: VoiceAudioClip) {
        let recording = VoiceRecording(
            id: clip.id,
            controllerID: controllerID.rawValue,
            sessionID: sessionID,
            createdAt: Date(),
            durationMs: clip.durationMs,
            fileName: "\(clip.id).\(clip.url.pathExtension)",
            mimeType: clip.mimeType
        )
        let stored = try? archive.add(recording, movingFileAt: clip.url)
        let fileURL = stored.map(archive.fileURL(for:)) ?? clip.url
        let echoContext = [previousSentence, speakingText].joined(separator: " ")
        let overlapped = clip.overlappedReply
        if turnStartedAt == nil { turnStartedAt = Date() }
        transcribing += 1
        refreshPhase()
        Task { [weak self] in
            guard let self else { return }
            let audio = (try? Data(contentsOf: fileURL)) ?? Data()
            let result: VoiceTranscription
            do {
                result = try await self.store.transcribeVoice(audio: audio, filename: fileURL.lastPathComponent, mimeType: clip.mimeType)
            } catch {
                self.transcribing -= 1
                self.notice = "Couldn't transcribe that: \(error.localizedDescription)"
                self.engine.play(.dropped)
                self.engine.duckReplies(false)
                if self.turnUtterances.isEmpty { self.turnStartedAt = nil }
                self.refreshPhase()
                return
            }
            self.transcribing -= 1
            self.archive.update(id: clip.id) {
                $0.transcript = result.text
                $0.model = result.model
            }
            self.accept(result.text, utteranceID: clip.id, overlapped: overlapped, echoContext: echoContext)
        }
    }

    private func accept(_ text: String, utteranceID: String, overlapped: Bool, echoContext: String) {
        if text.isEmpty || VoiceFiller.isFillerOnly(text) {
            // Nothing, or only "hmm"/"uh": room noise the level gate let through, not a turn.
            engine.duckReplies(false)
        } else if overlapped && VoiceEcho.isEcho(heard: text, spoken: echoContext) {
            // The reply leaking back into the mic, not you.
            engine.duckReplies(false)
            archive.update(id: utteranceID) { $0.echo = true }
        } else {
            // Two words of yours cut the reply; a single word joins your turn and lets it finish.
            if overlapped && VoiceEcho.isBargeIn(heard: text, spoken: echoContext) {
                interruptReply()
            } else {
                engine.duckReplies(false)
            }
            notice = nil
            turnUtterances.append((utteranceID, text))
            heardText = VoiceTurnPolicy.join(turnUtterances.map(\.text))
        }
        if turnUtterances.isEmpty { turnStartedAt = nil }
        refreshPhase()
        evaluateTurn()
    }

    // MARK: Your turn

    private func evaluateTurn() {
        guard !isPaused, !turnUtterances.isEmpty, let started = turnStartedAt else { return }
        holdTask?.cancel()
        switch policy.decide(text: heardText, speaking: userSpeaking, transcribing: transcribing > 0, turnStartedAt: started, now: Date(), speechEndedAt: speechEndedAt) {
        case .send:
            sendTurn()
        case .wait:
            break
        case .hold(let until):
            holdTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0, until.timeIntervalSinceNow)))
                guard !Task.isCancelled, let self, !self.userSpeaking, self.transcribing == 0, !self.isPaused else { return }
                self.sendTurn()
            }
        }
    }

    private func sendTurn() {
        holdTask?.cancel()
        let text = heardText
        let ids = turnUtterances.map(\.id)
        turnUtterances = []
        turnStartedAt = nil
        heardText = ""
        guard !text.isEmpty else { return }
        archive.markTurn(ids: ids, text: text)
        phase = .sending
        Task { [weak self] in
            guard let self else { return }
            // Through the composer's send, so anything attached from the strip goes with the spoken turn.
            switch await self.store.sendComposer(text: text, to: self.sessionID, voice: true) {
            case .success:
                self.engine.play(.gotIt)
                self.awaitingReply = true
                self.lastSoundAt = Date()
            case .failure(let error):
                self.engine.play(.dropped)
                self.notice = "Couldn't send: \(error.errorDescription ?? "unknown error")"
            }
            self.refreshPhase()
        }
    }

    // MARK: The agent's turn

    private func tick() {
        guard let sessionStore = store.openSession(sessionID) else { return }
        let entries = sessionStore.entries
        let signature = "\(entries.count):\(entries.last?.id ?? ""):\(entries.last?.rev ?? 0)"
        if signature != transcriptSignature {
            transcriptSignature = signature
            for event in tracker.events(in: entries) { apply(event) }
        }
        announceNewApprovals()
        if awaitingReply, !isSpeaking, !isPaused, !userSpeaking, Date().timeIntervalSince(lastSoundAt) > 4 {
            engine.play(.working)
            lastSoundAt = Date()
        }
        updateLiveActivity()
    }

    // MARK: Live Activity

    private var currentLiveActivityState: VoiceActivityAttributes.ContentState {
        let line: String
        switch phase {
        case .speaking: line = speakingText
        case .hearing, .sending: line = heardText
        case .failed(let message): line = message
        default: line = ""
        }
        return VoiceActivityAttributes.ContentState(phase: phase.label, symbol: phase.symbol, line: line, isPaused: isPaused, isMicMuted: isMicMuted)
    }

    /// Voice mode on the lock screen and in the Dynamic Island while it runs.
    private func startLiveActivity() {
        guard liveActivity == nil, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = currentLiveActivityState
        do {
            liveActivity = try Activity.request(
                attributes: VoiceActivityAttributes(sessionName: sessionName),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            liveActivityState = state
        } catch {
            voiceLiveActivityLogger.error("Live Activity did not start: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Checked on every tick; only a changed state is sent.
    private func updateLiveActivity() {
        guard let activity = liveActivity else { return }
        let state = currentLiveActivityState
        guard state != liveActivityState else { return }
        liveActivityState = state
        LiveActivityHandle(activity: activity).update(state)
    }

    private func endLiveActivity() {
        guard let activity = liveActivity else { return }
        liveActivity = nil
        liveActivityState = nil
        LiveActivityHandle(activity: activity).end()
    }

    private func apply(_ event: VoiceReplyEvent) {
        switch event {
        case .speak(_, let text):
            let sentences = SpeakableText.sentences(SpeakableText.speakable(text))
            currentReply.append(contentsOf: sentences)
            sentenceQueue.append(contentsOf: sentences)
            startSpeaking()
        case .skip:
            break
        case .turnEnded:
            awaitingReply = false
            turnEndPending = true
            if !isSpeaking { finishAgentTurn() }
        case .stage(let entry):
            stage = entry
            if !stageHistory.contains(where: { $0.id == entry.id }) { stageHistory.append(entry) }
        }
    }

    private func announceNewApprovals() {
        let pending = store.sessions[sessionID]?.pending ?? []
        let ids = Set(pending.compactMap(\.requestId))
        let new = ids.subtracting(knownApprovalIDs)
        knownApprovalIDs = ids
        guard !new.isEmpty else { return }
        engine.play(.approval)
        let isQuestion = pending.contains { approval in approval.requestId.map(new.contains) == true && approval.kind == .question }
        sentenceQueue.append(isQuestion ? "Question for you." : "Approval needed.")
        startSpeaking()
    }

    private func startSpeaking() {
        guard speakingTask == nil, !sentenceQueue.isEmpty else { return }
        canReplay = true
        speakingTask = Task { [weak self] in
            await self?.speakQueue()
        }
    }

    /// You're talking, or what you said hasn't been sent yet.
    private var yourTurnOpen: Bool {
        userSpeaking || transcribing > 0 || !turnUtterances.isEmpty
    }

    private func speakQueue() async {
        var cuts = 0
        while !Task.isCancelled, !sentenceQueue.isEmpty {
            while isPaused {
                try? await Task.sleep(for: .milliseconds(200))
                if Task.isCancelled { return }
            }
            // Your voice wins: a reply that arrives while you're talking (or before what you said is sent) waits, and
            // one already playing stops after its sentence. It used to talk over you, and with its echo raising the
            // bar for speech, the rest of what you said went unheard (Shitiz, 28 Nov).
            if yourTurnOpen {
                speakingText = ""
                refreshPhase()
                while yourTurnOpen || isPaused {
                    try? await Task.sleep(for: .milliseconds(200))
                    if Task.isCancelled { return }
                }
            }
            let sentence = sentenceQueue.removeFirst()
            if let next = sentenceQueue.first { prefetch(next) }
            guard let pcm = await audio(for: sentence) else { continue }
            if Task.isCancelled { return }
            speakingText = sentence
            phase = .speaking
            updateNowPlaying()
            let finished = await withCheckedContinuation { continuation in
                engine.playReply(pcm: pcm) { finished in continuation.resume(returning: finished) }
            }
            lastSoundAt = Date()
            if !finished {
                // An interrupt cancels this task first. Anything else that cuts a sentence is the engine restarting
                // (muting the mic for pause or an AirPods route change can rebuild its graph): the sentence goes back
                // on the queue and plays again, then the rest, once the engine is back and you've resumed. This
                // loop used to return here and leave speakingTask set, so nothing was ever spoken again.
                if Task.isCancelled { return }
                cuts += 1
                guard cuts <= 5 else { break }
                sentenceQueue.insert(sentence, at: 0)
                try? await Task.sleep(for: .milliseconds(400))
                continue
            }
            cuts = 0
            previousSentence = sentence
        }
        guard !Task.isCancelled else { return }
        speakingTask = nil
        speakingText = ""
        engine.duckReplies(false)
        if turnEndPending { finishAgentTurn() } else { refreshPhase() }
    }

    private func finishAgentTurn() {
        turnEndPending = false
        if !currentReply.isEmpty {
            lastReply = currentReply
            currentReply = []
        }
        audioCache = audioCache.filter { lastReply.contains($0.key) }
        engine.play(.yourTurn)
        lastSoundAt = Date()
        refreshPhase()
    }

    private func interruptReply() {
        speakingTask?.cancel()
        speakingTask = nil
        sentenceQueue = []
        engine.stopReplies()
        speakingText = ""
        if turnEndPending { finishAgentTurn() } else { refreshPhase() }
    }

    private func prefetch(_ sentence: String) {
        guard audioCache[sentence] == nil, fetches[sentence] == nil else { return }
        let store = store
        let voice = VoiceSettings.voice
        let speed = VoiceSettings.speed
        fetches[sentence] = Task { try? await store.synthesizeVoice(text: sentence, voice: voice, speed: speed) }
    }

    private func audio(for sentence: String) async -> Data? {
        if let cached = audioCache[sentence] { return cached }
        prefetch(sentence)
        let data = await fetches[sentence]?.value
        fetches[sentence] = nil
        if let data, !data.isEmpty {
            audioCache[sentence] = data
            return data
        }
        notice = "Couldn't get the voice from the host."
        engine.play(.dropped)
        return nil
    }

    private func refreshPhase() {
        if case .failed = phase { return }
        if isPaused { phase = .paused }
        else if engine.isReplyPlaying || !speakingText.isEmpty { phase = .speaking }
        else if isMicMuted { phase = .muted }
        else if userSpeaking { phase = .hearing }
        else if transcribing > 0 || !turnUtterances.isEmpty { phase = .hearing }
        else if awaitingReply { phase = .working }
        else { phase = .listening }
        updateNowPlaying()
    }

    // MARK: Lock screen and AirPods

    private func setUpRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        let toggle = center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePause() }
            return .success
        }
        let play = center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.setPaused(false) }
            return .success
        }
        let pause = center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.setPaused(true) }
            return .success
        }
        center.togglePlayPauseCommand.isEnabled = true
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        remoteTargets = [(center.togglePlayPauseCommand, toggle), (center.playCommand, play), (center.pauseCommand, pause)]

        // While the mic is open in a voice-chat session, iOS treats an AirPods press as a call control, so the
        // play/pause commands above only arrive from the lock screen and Control Center. The press reaches the app
        // as iOS 17's press-to-mute gesture instead; observing it opts in, iOS mutes the mic itself, and voice mode
        // pauses with it.
        muteGestureObserver = NotificationCenter.default.addObserver(
            forName: AVAudioApplication.inputMuteStateChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let muted = (notification.userInfo?[AVAudioApplication.muteStateKey] as? NSNumber)?.boolValue ?? false
            MainActor.assumeIsolated { self?.systemMicMuteChanged(muted) }
        }
    }

    /// An AirPods press (or Control Centre) toggled the system's mic mute. Changes the app made itself are ignored. A
    /// press mutes the mic and lets the reply play on; pressing again while paused resumes everything.
    private func systemMicMuteChanged(_ muted: Bool) {
        guard muted != (isPaused || isMicMuted) else { return }
        if !muted, isPaused {
            isMicMuted = false
            setPaused(false)
        } else {
            setMicMuted(muted)
        }
    }

    private func tearDownRemoteCommands() {
        for (command, target) in remoteTargets { command.removeTarget(target) }
        remoteTargets = []
        if let muteGestureObserver { NotificationCenter.default.removeObserver(muteGestureObserver) }
        muteGestureObserver = nil
    }

    private func updateNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: speakingText.isEmpty ? phase.label : speakingText,
            MPMediaItemPropertyArtist: "Voice · \(sessionName)",
            MPNowPlayingInfoPropertyPlaybackRate: isPaused ? 0.0 : 1.0,
        ]
        info[MPNowPlayingInfoPropertyIsLiveStream] = true
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

/// The voice and speed replies are spoken in. Nil voice means the host's default.
enum VoiceSettings {
    private static let voiceKey = "voiceModeVoice"
    static let speedKey = "voiceModeSpeed"
    static let pauseKey = "voiceModePause"
    /// Voice mode plays over other apps' audio (a podcast keeps going, lowered while either of you talks) instead of
    /// stopping it. Off by default: a mixable session may not be the lock screen's Now Playing app. Read when voice
    /// mode starts.
    static let mixKey = "voiceModeMixesOtherAudio"

    static var mixesOtherAudio: Bool { UserDefaults.standard.bool(forKey: mixKey) }
    /// Seconds after your last words before a finished thought is sent. 0 in storage is the default.
    static let pauseChoices: [Double] = [1, 0, 3.5]
    static let defaultPause = 2.0

    static func pauseLabel(_ value: Double) -> String {
        switch value {
        case 1: "Short"
        case 3.5: "Long"
        default: "Normal"
        }
    }

    static var pause: Double {
        let value = UserDefaults.standard.double(forKey: pauseKey)
        return value > 0 ? value : defaultPause
    }
    /// 0 is the host's normal speed.
    static let speedChoices: [Double] = [0.8, 0, 1.2, 1.4, 1.6, 1.8, 2.0]

    static func speedLabel(_ value: Double) -> String {
        let shown = value > 0 ? value : 1
        return shown == shown.rounded() ? "\(Int(shown))×" : String(format: "%.1f×", shown)
    }

    static var voice: String? {
        get { UserDefaults.standard.string(forKey: voiceKey).flatMap { $0.isEmpty ? nil : $0 } }
        set { UserDefaults.standard.set(newValue, forKey: voiceKey) }
    }

    static var speed: Double? {
        get {
            let value = UserDefaults.standard.double(forKey: speedKey)
            return value > 0 ? value : nil
        }
        set { UserDefaults.standard.set(newValue ?? 0, forKey: speedKey) }
    }
}

/// The one voice conversation that can be on at a time, the recordings archive, and Read aloud outside voice mode.
@MainActor @Observable
final class VoiceCenter {
    static let shared = VoiceCenter()

    private(set) var active: VoiceModeController?
    /// The message being read aloud outside voice mode.
    private(set) var readingID: String?
    let archive = VoiceRecordingArchive(directory: VoiceRecordingArchive.standardDirectory())

    @ObservationIgnored private var reader: VoiceAudioEngine?
    @ObservationIgnored private var readingTask: Task<Void, Never>?

    init() {
        VoiceActivityActions.togglePause = { [weak self] in self?.active?.togglePause() }
        VoiceActivityActions.toggleMic = { [weak self] in self?.active?.toggleMicMute() }
        VoiceActivityActions.end = { [weak self] in self?.stop() }
        // A Live Activity left by a run that ended without stopping voice mode (a crash, a force quit). Taken now,
        // so a conversation started right after launch keeps its own.
        for activity in Activity<VoiceActivityAttributes>.activities {
            LiveActivityHandle(activity: activity).end()
        }
    }

    func isActive(controllerID: ControllerID, sessionID: String) -> Bool {
        active?.controllerID == controllerID && active?.sessionID == sessionID
    }

    func start(store: AppStore, controllerID: ControllerID, sessionID: String, sessionName: String) {
        stopReading()
        active?.stop()
        let controller = VoiceModeController(store: store, controllerID: controllerID, sessionID: sessionID, sessionName: sessionName, archive: archive)
        active = controller
        Task { await controller.start() }
    }

    func stop() {
        active?.stop()
        active = nil
    }

    /// Reads one message aloud. Inside its own voice conversation it joins the spoken queue; otherwise it plays on
    /// its own, without the mic.
    func readAloud(_ markdown: String, id: String, store: AppStore, controllerID: ControllerID, sessionID: String) {
        if let active, active.controllerID == controllerID, active.sessionID == sessionID {
            active.readAloud(markdown)
            return
        }
        guard active == nil else { return }
        stopReading()
        let sentences = SpeakableText.sentences(SpeakableText.speakable(markdown))
        guard !sentences.isEmpty else { return }
        let engine = VoiceAudioEngine()
        reader = engine
        readingID = id
        let voice = VoiceSettings.voice
        let speed = VoiceSettings.speed
        readingTask = Task { [weak self] in
            do {
                try await engine.start(listen: false)
            } catch {
                self?.stopReading()
                return
            }
            var next: Task<Data?, Never>? = Task { try? await store.synthesizeVoice(text: sentences[0], voice: voice, speed: speed) }
            for index in sentences.indices {
                guard let current = next, !Task.isCancelled else { break }
                next = index + 1 < sentences.count
                    ? Task { try? await store.synthesizeVoice(text: sentences[index + 1], voice: voice, speed: speed) }
                    : nil
                guard let pcm = await current.value else { continue }
                let finished = await withCheckedContinuation { continuation in
                    engine.playReply(pcm: pcm) { finished in continuation.resume(returning: finished) }
                }
                if !finished { break }
            }
            self?.finishReading(engine)
        }
    }

    func stopReading() {
        readingTask?.cancel()
        readingTask = nil
        reader?.stopReplies()
        reader?.stop()
        reader = nil
        readingID = nil
    }

    private func finishReading(_ engine: VoiceAudioEngine) {
        guard reader === engine else { return }
        engine.stop()
        reader = nil
        readingID = nil
        readingTask = nil
    }
}
