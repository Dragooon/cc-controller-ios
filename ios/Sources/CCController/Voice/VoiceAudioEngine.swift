import AVFoundation
import CCKit
import Foundation
import os

enum VoiceAudioError: LocalizedError {
    case noMicrophone
    var errorDescription: String? { "No microphone is available." }
}

/// What the mic side of voice mode reports to the controller.
enum VoiceAudioEvent: Sendable {
    /// The phone started hearing speech.
    case speechStarted
    /// An utterance ended at a pause. The clip is an AAC file in the temporary directory.
    case utterance(VoiceAudioClip)
    /// A speech start that came to nothing (too short to be words).
    case speechDiscarded
    /// The audio system interrupted or rebuilt the engine and couldn't restart it.
    case failed(String)
}

struct VoiceAudioClip: Sendable {
    let id: String
    let url: URL
    let durationMs: Int
    /// Started while a reply was playing.
    let overlappedReply: Bool
    var mimeType = "audio/mp4"
}

/// The cues voice mode plays: short generated tones, VoiceMode's approach, each with a moment of silence in front so
/// Bluetooth headsets are awake when the tone starts.
enum VoiceCue: CaseIterable, Sendable {
    case gotIt, working, yourTurn, muted, listening, approval, dropped

    /// (frequency in Hz, seconds) per note.
    var notes: [(Double, Double)] {
        switch self {
        case .gotIt: [(1175, 0.07), (1568, 0.09)]
        case .working: [(660, 0.05)]
        case .yourTurn: [(880, 0.08), (1175, 0.12)]
        case .muted: [(700, 0.08), (500, 0.12)]
        case .listening: [(500, 0.08), (700, 0.12)]
        case .approval: [(988, 0.08), (988, 0.08), (1319, 0.12)]
        case .dropped: [(784, 0.12), (523, 0.2)]
        }
    }

    var volume: Float { self == .working ? 0.18 : 0.35 }
}

/// Owns the audio side of voice mode: one engine with iOS voice processing (echo cancellation) on, the mic tap that
/// finds utterances, the player for replies and the cue player.
@MainActor
final class VoiceAudioEngine {
    let events: AsyncStream<VoiceAudioEvent>

    private let engine = AVAudioEngine()
    private let replyPlayer = AVAudioPlayerNode()
    private let cuePlayer = AVAudioPlayerNode()
    private let replyFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: VoiceSpeechFormat.sampleRate, channels: 1, interleaved: false)!
    private let cueFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    private let continuation: AsyncStream<VoiceAudioEvent>.Continuation
    private let processor: VoiceTapProcessor
    private var observers: [NSObjectProtocol] = []
    private var cueBuffers: [VoiceCue: AVAudioPCMBuffer] = [:]
    private var listens = false
    private(set) var isRunning = false
    private var isStarting = false
    private var startedAt = Date.distantPast
    /// Reply sentences scheduled and not yet played, by token.
    private var pendingReplyFinishes: [Int: @MainActor @Sendable (Bool) -> Void] = [:]
    private var nextReplyToken = 0
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cc-controller", category: "voice")

    init() {
        var continuation: AsyncStream<VoiceAudioEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.continuation = continuation
        processor = VoiceTapProcessor(events: continuation)
        for cue in VoiceCue.allCases { cueBuffers[cue] = makeCueBuffer(cue) }
    }

    // MARK: Lifecycle

    /// AVAudioSession activation and engine start wait on the audio server (iOS 27 warns that they can freeze the UI
    /// on the main thread), so they run on this queue while the main actor awaits. Serial, so a stop's deactivation
    /// always lands before the next start's activation.
    private static let audioQueue = DispatchQueue(label: "voice-audio", qos: .userInitiated)

    private struct Unchecked<Value>: @unchecked Sendable { let value: Value }

    private static func onAudioQueue(_ work: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            audioQueue.async {
                do {
                    try work()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Starts the engine. `listen` opens the mic with echo cancellation (voice mode); without it the engine only
    /// plays (Read aloud).
    func start(listen: Bool) async throws {
        if isStarting { return }
        if isRunning, listens == listen { return }
        if isRunning { stop() }
        isStarting = true
        defer { isStarting = false }
        listens = listen
        let engineBox = Unchecked(value: engine)
        try await Self.onAudioQueue {
            let session = AVAudioSession.sharedInstance()
            if listen {
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
            } else {
                try session.setCategory(.playback, mode: .spokenAudio, options: [])
            }
            try session.setActive(true)
            if listen {
                try engineBox.value.inputNode.setVoiceProcessingEnabled(true)
            }
        }
        engine.attach(replyPlayer)
        engine.attach(cuePlayer)
        engine.connect(replyPlayer, to: engine.mainMixerNode, format: replyFormat)
        engine.connect(cuePlayer, to: engine.mainMixerNode, format: cueFormat)
        if listen { try installTap() }
        try await Self.onAudioQueue {
            engineBox.value.prepare()
            try engineBox.value.start()
        }
        replyPlayer.play()
        cuePlayer.play()
        isRunning = true
        startedAt = Date()
        observeSession()
    }

    func stop() {
        removeObservers()
        if listens { engine.inputNode.removeTap(onBus: 0) }
        replyPlayer.stop()
        cuePlayer.stop()
        engine.stop()
        if listens { try? engine.inputNode.setVoiceProcessingEnabled(false) }
        engine.detach(replyPlayer)
        engine.detach(cuePlayer)
        processor.reset()
        let cut = pendingReplyFinishes
        pendingReplyFinishes = [:]
        isRunning = false
        for finish in cut.values { finish(false) }
        Self.audioQueue.async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: Mic

    /// While muted the mic is still open (so the engine keeps its echo canceller warm) but nothing is heard.
    func setMuted(_ muted: Bool) { processor.setMuted(muted) }

    private func installTap() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw VoiceAudioError.noMicrophone }
        processor.configure(sampleRate: format.sampleRate)
        input.installTap(onBus: 0, bufferSize: 1_024, format: format, block: VoiceTapProcessor.tapBlock(for: processor))
    }

    // MARK: Replies

    /// Queues one sentence of the host's PCM. `onFinish(true)` runs on the main actor once it has played, and
    /// `onFinish(false)` if `stopReplies` cut it off first.
    func playReply(pcm: Data, onFinish: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard isRunning, let buffer = makeReplyBuffer(pcm) else {
            onFinish(false)
            return
        }
        nextReplyToken += 1
        let token = nextReplyToken
        pendingReplyFinishes[token] = onFinish
        processor.setReplyPlaying(true)
        replyPlayer.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable [weak self] _ in
            Task { @MainActor in
                guard let self, let finish = self.pendingReplyFinishes.removeValue(forKey: token) else { return }
                if self.pendingReplyFinishes.isEmpty { self.processor.setReplyPlaying(false) }
                finish(true)
            }
        }
        if !replyPlayer.isPlaying { replyPlayer.play() }
    }

    /// Drops every queued sentence and stops the one playing.
    func stopReplies() {
        let cut = pendingReplyFinishes
        pendingReplyFinishes = [:]
        replyPlayer.stop()
        replyPlayer.volume = 1
        processor.setReplyPlaying(false)
        if isRunning { replyPlayer.play() }
        for finish in cut.values { finish(false) }
    }

    func pauseReplies() { replyPlayer.pause() }
    func resumeReplies() { if isRunning { replyPlayer.play() } }

    /// Lowers the reply while you might be talking over it, and restores it.
    func duckReplies(_ ducked: Bool) { replyPlayer.volume = ducked ? 0.25 : 1 }

    var isReplyPlaying: Bool { !pendingReplyFinishes.isEmpty }

    // MARK: Cues

    func play(_ cue: VoiceCue) {
        guard isRunning, let buffer = cueBuffers[cue] else { return }
        cuePlayer.volume = cue.volume
        cuePlayer.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        if !cuePlayer.isPlaying { cuePlayer.play() }
    }

    // MARK: Buffers

    private func makeReplyBuffer(_ pcm: Data) -> AVAudioPCMBuffer? {
        let frames = pcm.count / VoiceSpeechFormat.bytesPerSample
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: replyFormat, frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for index in 0..<frames {
                channel[index] = Float(Int16(littleEndian: samples[index])) / 32_768
            }
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        return buffer
    }

    private func makeCueBuffer(_ cue: VoiceCue) -> AVAudioPCMBuffer? {
        let rate = cueFormat.sampleRate
        let lead = 0.1
        let gap = 0.03
        let total = lead + cue.notes.reduce(0) { $0 + $1.1 + gap }
        let frames = AVAudioFrameCount(total * rate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: cueFormat, frameCapacity: frames),
              let channel = buffer.floatChannelData?[0] else { return nil }
        for index in 0..<Int(frames) { channel[index] = 0 }
        var cursor = Int(lead * rate)
        for (frequency, seconds) in cue.notes {
            let count = Int(seconds * rate)
            let fade = min(count / 4, Int(0.01 * rate))
            for sample in 0..<count where cursor + sample < Int(frames) {
                var envelope: Float = 1
                if sample < fade { envelope = Float(sample) / Float(fade) }
                if sample > count - fade { envelope = Float(count - sample) / Float(fade) }
                channel[cursor + sample] = envelope * Float(sin(2 * Double.pi * frequency * Double(sample) / rate))
            }
            cursor += count + Int(gap * rate)
        }
        buffer.frameLength = frames
        return buffer
    }

    // MARK: Session changes

    private func observeSession() {
        removeObservers()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated { self?.handleInterruption(typeValue: typeValue) }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartAfterChange() }
        })
    }

    private func removeObservers() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    private func handleInterruption(typeValue: UInt?) {
        guard let typeValue, let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        if type == .ended { restartAfterChange() }
    }

    /// A route change (AirPods in or out) or an interruption rebuilds the engine's graph; start it again. Turning
    /// voice processing on raises a change of its own right after start, which is ignored.
    private func restartAfterChange() {
        guard isRunning, Date().timeIntervalSince(startedAt) > 1.5 else { return }
        let listen = listens
        stop()
        Task { [weak self] in
            do {
                try await self?.start(listen: listen)
            } catch {
                Self.logger.error("voice engine restart failed: \(error.localizedDescription, privacy: .public)")
                self?.continuation.yield(.failed("The audio stopped: \(error.localizedDescription)"))
            }
        }
    }
}

/// Runs on the mic tap's thread: finds speech with an adaptive noise floor in the speech band (walkie-talkie keeps
/// to 200–4000 Hz so wind and road rumble don't count), keeps a short pre-roll so the first syllable isn't lost, and
/// writes each utterance to an AAC file.
final class VoiceTapProcessor: @unchecked Sendable {
    private let lock = NSLock()
    private let events: AsyncStream<VoiceAudioEvent>.Continuation

    // Settings, guarded by `lock`.
    private var muted = false
    private var replyPlaying = false

    // Tap-thread state.
    private var sampleRate: Double = 48_000
    private var highPass = Biquad()
    private var lowPass = Biquad()
    private var noiseFloor: Float = -60
    private var speechFrames = 0
    private var silenceSeconds: Double = 0
    private var speaking = false
    private var utteranceSeconds: Double = 0
    private var preRoll: [AVAudioPCMBuffer] = []
    private var preRollSeconds: Double = 0
    private var writer: AVAudioFile?
    private var writerURL: URL?
    private var writerID = ""
    private var overlappedReply = false

    /// Speech must stay above the floor this long to start an utterance.
    private let startSeconds = 0.15
    /// A pause this long ends an utterance.
    private let endSilenceSeconds = 1.0
    /// Utterances shorter than this are dropped as noise.
    private let minimumUtteranceSeconds = 0.4
    /// The longest utterance; the host refuses clips over two minutes.
    private let maximumUtteranceSeconds = 110.0
    private let preRollLimitSeconds = 0.4

    init(events: AsyncStream<VoiceAudioEvent>.Continuation) {
        self.events = events
    }

    /// Built outside any actor, so the engine can call it from the audio thread.
    nonisolated static func tapBlock(for processor: VoiceTapProcessor) -> AVAudioNodeTapBlock {
        { @Sendable buffer, _ in processor.process(buffer) }
    }

    func configure(sampleRate: Double) {
        lock.lock(); defer { lock.unlock() }
        self.sampleRate = sampleRate
        highPass = Biquad.highPass(frequency: 200, sampleRate: sampleRate)
        lowPass = Biquad.lowPass(frequency: 4_000, sampleRate: sampleRate)
    }

    func setMuted(_ value: Bool) {
        lock.lock(); muted = value; lock.unlock()
    }

    func setReplyPlaying(_ value: Bool) {
        lock.lock(); replyPlaying = value; lock.unlock()
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        finishWriter(keep: false)
        speaking = false
        speechFrames = 0
        silenceSeconds = 0
        preRoll = []
        preRollSeconds = 0
        noiseFloor = -60
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let mono = monoCopy(of: buffer) else { return }
        let seconds = Double(mono.frameLength) / sampleRate

        if muted {
            if speaking { finishWriter(keep: false); speaking = false; events.yield(.speechDiscarded) }
            return
        }

        let level = bandLevel(of: mono)
        // Echo from the reply survives the canceller a little, so speech has to be louder while it plays.
        let margin: Float = replyPlaying ? 16 : 10
        let threshold = max(noiseFloor + margin, -52)

        if !speaking {
            // The floor follows the room when nobody is talking.
            if level < threshold { noiseFloor = noiseFloor * 0.98 + level * 0.02 }
            appendPreRoll(mono, seconds: seconds)
            if level > threshold {
                speechFrames += 1
                if Double(speechFrames) * seconds >= startSeconds { beginUtterance() }
            } else {
                speechFrames = 0
            }
            return
        }

        write(mono)
        utteranceSeconds += seconds
        if level > threshold - 3 {
            silenceSeconds = 0
        } else {
            silenceSeconds += seconds
        }
        if silenceSeconds >= endSilenceSeconds || utteranceSeconds >= maximumUtteranceSeconds {
            endUtterance()
        }
    }

    private func beginUtterance() {
        speaking = true
        speechFrames = 0
        silenceSeconds = 0
        utteranceSeconds = preRollSeconds
        overlappedReply = replyPlaying
        writerID = UUID().uuidString.lowercased()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("utterance-\(writerID).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        writer = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        writerURL = url
        for buffer in preRoll { write(buffer) }
        preRoll = []
        preRollSeconds = 0
        events.yield(.speechStarted)
    }

    private func endUtterance() {
        speaking = false
        let spokenSeconds = utteranceSeconds - silenceSeconds
        guard spokenSeconds >= minimumUtteranceSeconds, let url = writerURL else {
            finishWriter(keep: false)
            events.yield(.speechDiscarded)
            return
        }
        finishWriter(keep: true)
        events.yield(.utterance(VoiceAudioClip(id: writerID, url: url, durationMs: Int(utteranceSeconds * 1_000), overlappedReply: overlappedReply)))
    }

    private func finishWriter(keep: Bool) {
        writer = nil  // AVAudioFile finishes the file when released.
        if !keep, let writerURL { try? FileManager.default.removeItem(at: writerURL) }
        writerURL = nil
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        try? writer?.write(from: buffer)
    }

    private func appendPreRoll(_ buffer: AVAudioPCMBuffer, seconds: Double) {
        preRoll.append(buffer)
        preRollSeconds += seconds
        while preRollSeconds > preRollLimitSeconds, preRoll.count > 1 {
            let dropped = preRoll.removeFirst()
            preRollSeconds -= Double(dropped.frameLength) / sampleRate
        }
    }

    /// Channel 0 as its own mono buffer: the engine reuses the tap's buffer, and voice processing can hand over
    /// more than one channel.
    private func monoCopy(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let source = buffer.floatChannelData?[0],
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let destination = copy.floatChannelData?[0] else { return nil }
        destination.update(from: source, count: Int(buffer.frameLength))
        copy.frameLength = buffer.frameLength
        return copy
    }

    /// The buffer's loudness in the speech band, in dBFS.
    private func bandLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return -120 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) {
            let filtered = lowPass.process(highPass.process(samples[index]))
            sum += filtered * filtered
        }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        return 20 * log10(max(rms, 1e-6))
    }
}

/// A second-order filter (RBJ cookbook).
struct Biquad {
    private var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    static func highPass(frequency: Double, sampleRate: Double, q: Double = 0.707) -> Biquad {
        let omega = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(omega) / (2 * q)
        let cosine = cos(omega)
        let a0 = 1 + alpha
        var filter = Biquad()
        filter.b0 = Float((1 + cosine) / 2 / a0)
        filter.b1 = Float(-(1 + cosine) / a0)
        filter.b2 = Float((1 + cosine) / 2 / a0)
        filter.a1 = Float(-2 * cosine / a0)
        filter.a2 = Float((1 - alpha) / a0)
        return filter
    }

    static func lowPass(frequency: Double, sampleRate: Double, q: Double = 0.707) -> Biquad {
        let omega = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(omega) / (2 * q)
        let cosine = cos(omega)
        let a0 = 1 + alpha
        var filter = Biquad()
        filter.b0 = Float((1 - cosine) / 2 / a0)
        filter.b1 = Float((1 - cosine) / a0)
        filter.b2 = Float((1 - cosine) / 2 / a0)
        filter.a1 = Float(-2 * cosine / a0)
        filter.a2 = Float((1 - alpha) / a0)
        return filter
    }

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x
        y2 = y1; y1 = y
        return y
    }
}
