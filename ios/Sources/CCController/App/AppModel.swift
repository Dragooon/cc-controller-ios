import CCKit
import Foundation
import LocalAuthentication
import Observation
import SwiftUI
import UIKit
import os
import UserNotifications

private let authLogger = Logger(
    subsystem: "com.example.cc-controller",
    category: "auth"
)

@MainActor @Observable
final class AppModel {
    enum Phase: Equatable {
        case onboarding
        case locked
        case unlocked
    }

    let auth: AuthSession
    let store: AppStore
    private(set) var lockPolicy: LockPolicy
    let settings: SettingsStore

    var phase: Phase
    var selectedSessionID: String?
    var isPrivacyCovered = false
    var colorScheme: ColorScheme?
    var isSettingsPresented = false
    var actionError: ActionError?
    #if DEBUG || CC_PERF
    let debugAttachmentPaths: [URL]
    var keychainSelfTestResult: String?
    #endif
    var onboarding = OnboardingFlowState()
    var connectionMessage: String?
    var copiedPairingCommand = false
    var identityChanged = false
    var relayDiagnostics: RelayDiagnostics?
    var relayIdentityWarning: RelayEndpointDiagnostic?
    var isRelayWarningPresented = false
    var faceIDMessage: String?
    private(set) var isAuthenticating = false
    private(set) var isUnpairing = false

    var onboardingStep: OnboardingStep { onboarding.step }
    var pairingCode: String? { onboarding.pairingCode }
    var pairingExpiresAt: Date? { onboarding.pairingExpiresAt }
    var connectionAddress: String {
        if relayMode, let endpoint = transport.selectedEndpoint ?? relayEndpoints.first {
            return endpoint.host.map { "\($0):\(endpoint.port ?? 0)" } ?? endpoint.absoluteString
        }
        return serverURL.absoluteString.replacingOccurrences(of: "http://", with: "")
    }
    var connectionLabel: String {
        guard relayMode, let endpoint = transport.selectedEndpoint ?? relayEndpoints.first else { return "" }
        return relayEndpointLabel(for: endpoint)
    }
    var connection: OnboardingConnection { onboarding.connection }
    var relayMode: Bool { transport.mode == .relay }
    var relayEndpoints: [URL] { transport.configuredEndpoints }
    var relayPinGrouped: String? {
        (relayPin ?? transport.observedPin).flatMap { (try? RelayPin($0))?.grouped }
    }
    var relayPairingCheck: String? { transport.observedPin.flatMap { try? RelayPin($0).check } }
    var appVersion: String {
        let info = Bundle.main.infoDictionary
        return appVersionText(
            version: info?["CFBundleShortVersionString"] as? String,
            build: info?["CFBundleVersion"] as? String
        )
    }

    private let credentials: any CredentialStore
    private let fixtureMode: Bool
    private let debugOnboarding: Bool
    #if DEBUG
    private var debugPairingExpirySeconds: TimeInterval?
    #endif
    private let serverURL: URL
    private let transport: ConnectionRouter
    private var relayPin: String?
    private let relayDefaultEndpoints: [URL]
    private let relayDefaultsKey = "CCRelayEndpoints"
    private let lockIntervalStore: LockIntervalStore
    private var lockTransitionPolicy: LockTransitionPolicy
    private(set) var currentScenePhase: ScenePhase = .background
    private var connectionTask: Task<Void, Never>?
    private var pairingTask: Task<Void, Never>?
    private var notificationAuthorizationRequested = false
    private var nativeSecretEnrolledForOnboarding = false
    private var hasAutoPromptedLockScreen = false
    private var deviceName = "iPhone"
    private var isSettingsVisible = false
    private var observedSessions: [String: Session] = [:]
    private var pendingSessionReplacement: (missingID: String, missingAt: Date)?

    init(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        #if DEBUG || CC_PERF
        let bearer = environment["CCBearer"] ?? ""
        let serverOverride = Self.serverURL(arguments: arguments)
        let configuredEndpoints = Self.relayEndpoints(arguments: arguments)
        let serverURL = serverOverride ?? URL(string: "http://127.0.0.1:47832")!
        let isDebugOnboarding = arguments.contains("-CCOnboarding")
        let isFixture = Self.hasFixtureArguments(arguments: arguments, bearer: bearer) && !isDebugOnboarding
        debugAttachmentPaths = Self.argumentValues("-CCAttachFile", in: arguments).map { URL(fileURLWithPath: $0) }
        #else
        let bearer = ""
        let serverOverride: URL? = nil
        let configuredEndpoints = Self.relayEndpoints(arguments: [])
        let serverURL = URL(string: "http://127.0.0.1:47832")!
        let isDebugOnboarding = false
        let isFixture = false
        #endif
        #if DEBUG
        let initialTranscriptTail = isFixture
            ? Self.argumentValue("-CCFixtureInitialTranscriptTail", in: arguments).flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
            : nil
        #else
        let initialTranscriptTail: Int? = nil
        #endif
        self.serverURL = serverURL
        let credentials = KeychainCredentialStore()
        self.credentials = credentials
        let defaultEndpoints = Self.defaultRelayEndpoints()
        #if DEBUG || CC_PERF
        let argumentPin = Self.argumentValue("-CCRelayPin", in: arguments).flatMap { try? RelayPin($0) }
        #else
        let argumentPin: RelayPin? = nil
        #endif
        let transport: ConnectionRouter
        if serverOverride == nil, !configuredEndpoints.isEmpty {
            transport = ConnectionRouter(
                endpoints: configuredEndpoints,
                pin: argumentPin,
                pinLoader: { [credentials] in
                    guard let value = try? await credentials.getRelayPin() else { return nil }
                    return try? RelayPin(value)
                }
            )
        } else {
            transport = ConnectionRouter(baseURL: serverURL)
        }
        self.transport = transport
        self.relayPin = argumentPin?.value
        self.relayDefaultEndpoints = defaultEndpoints
        let lockIntervalStore = LockIntervalStore()
        self.lockIntervalStore = lockIntervalStore
        debugOnboarding = isDebugOnboarding
        #if DEBUG
        debugPairingExpirySeconds = Self.argumentValue("-CCPairingExpirySeconds", in: arguments).flatMap(TimeInterval.init)
        #endif
        fixtureMode = isFixture
        #if CC_PERF
        selectedSessionID = Self.argumentValue("-CCSession", in: arguments)
        #endif

        let cacheDirectory = Self.cacheDirectory()
        #if DEBUG
        if arguments.contains("-CCResetCache"), FileManager.default.fileExists(atPath: cacheDirectory.path) {
            do {
                try FileManager.default.removeItem(at: cacheDirectory)
            } catch {
                assertionFailure("Could not reset fixture cache: \(error)")
            }
        }
        #endif
        let auth = AuthSession(
            connection: transport,
            credentials: credentials,
            cacheDirectory: cacheDirectory
        )
        self.auth = auth
        #if DEBUG
        let lockInterval = Self.argumentValue("-CCLockInterval", in: arguments)
            .flatMap(TimeInterval.init)
            .map(LockInterval.custom) ?? lockIntervalStore.interval
        let lockPolicy = LockPolicy(interval: lockInterval)
        let probeInterval = Self.argumentValue("-CCProbeInterval", in: arguments)
            .flatMap(TimeInterval.init)
            .map { Duration.seconds($0) } ?? .seconds(2)
        self.lockPolicy = lockPolicy
        #else
        let lockPolicy = LockPolicy(interval: lockIntervalStore.interval)
        let probeInterval: Duration = .seconds(2)
        self.lockPolicy = lockPolicy
        #endif
        self.lockTransitionPolicy = LockTransitionPolicy(policy: lockPolicy)
        self.phase = fixtureMode ? .unlocked : .onboarding
        #if DEBUG
        self.colorScheme = Self.colorScheme(arguments: arguments)
        #else
        self.colorScheme = nil
        #endif
        self.deviceName = UIDevice.current.name
        let store = AppStore(
            connection: transport,
            bearerProvider: {
                #if DEBUG || CC_PERF
                if isFixture {
                    return bearer
                }
                #endif
                return try await auth.bearer()
            },
            cacheDirectory: cacheDirectory,
            authenticationFailureHandler: {
                _ = await auth.handleUnauthorized()
            },
            initialTranscriptTail: initialTranscriptTail ?? 100
        )
        self.store = store
        self.settings = SettingsStore(
            probe: { try await auth.probeDaemon(timeout: 5) },
            whoAmI: { try await store.whoAmI() },
            devices: { try await store.pairedDevices() },
            interval: probeInterval
        )
        observedSessions = store.sessions
        observeSessionReplacement()
        observeApprovalCount()
        Task { @MainActor [weak self] in
            await self?.updateBadgeCount()
        }
        #if DEBUG
        if arguments.contains("-CCKeychainSelfTest") {
            Task { @MainActor [weak self] in
                self?.keychainSelfTestResult = await Self.runKeychainSelfTest()
            }
        }
        #endif

        if transport.mode == .relay {
            Task { @MainActor [weak self, credentials] in
                guard let self else { return }
                relayPin = try? await credentials.getRelayPin()
            }
        }
        guard !fixtureMode else { return }
        Task { @MainActor [weak self, credentials] in
            guard let self else { return }
            if debugOnboarding {
                try? await credentials.deleteDeviceToken()
                try? await credentials.deleteNativeSecret()
                onboarding = OnboardingFlowState()
                phase = .onboarding
                return
            }
            let hasSecret = (try? await credentials.hasNativeSecret()) == true
            let hasToken = (try? await credentials.getDeviceToken()) != nil
            guard phase != .unlocked else { return }
            if transport.mode == .relay {
                let hasPin = (try? await credentials.getRelayPin()).flatMap { try? RelayPin($0) } != nil
                if relayCredentialPolicy(hasPin: hasPin, hasCredentials: hasSecret || hasToken) == .clearAndPairAgain {
                    try? await credentials.deleteDeviceToken()
                    try? await credentials.deleteNativeSecret()
                    onboarding = OnboardingFlowState()
                    onboarding.continueFromWelcome()
                    connectionMessage = "Pair this iPhone again to connect through the relay."
                    phase = .onboarding
                    startConnectionCheck()
                    return
                }
            }
            if hasSecret {
                transitionToLocked()
            } else {
                phase = .onboarding
            }
        }
    }

    func unlock() async {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }

        let result = await auth.unlock()
        let errorCode = auth.lastUnlockFailureCode ?? "none"
        switch result {
        case .success:
            authLogger.notice("unlock result=success errorCode=\(errorCode, privacy: .public)")
        case .failure:
            authLogger.error("unlock result=failure errorCode=\(errorCode, privacy: .public)")
        }
        switch result {
        case .success:
            faceIDMessage = nil
            phase = .unlocked
        case .failure(let error):
            await handleUnlockFailure(error)
        }
    }

    private func promptLockIfNeeded() {
        guard phase == .locked, currentScenePhase == .active, !hasAutoPromptedLockScreen else { return }
        hasAutoPromptedLockScreen = true
        #if DEBUG
        authLogger.notice("auto-prompt trigger")
        #endif
        Task { @MainActor [weak self] in
            await self?.unlock()
        }
    }

    func continueFromWelcome() {
        onboarding.continueFromWelcome()
        connectionMessage = nil
        startConnectionCheck()
    }

    func goBackFromConnect() {
        connectionTask?.cancel()
        onboarding = OnboardingFlowState()
        connectionMessage = nil
    }

    func goBackToConnect() {
        pairingTask?.cancel()
        onboarding.restartPairing()
        connectionMessage = nil
        faceIDMessage = nil
        startConnectionCheck()
    }

    func startConnectionCheck() {
        connectionTask?.cancel()
        guard onboardingStep == .connect else { return }
        onboarding.markConnectionChecking()
        connectionTask = Task { @MainActor [weak self] in
            var failedSince: Date?
            while !Task.isCancelled {
                guard let self, phase == .onboarding, onboardingStep == .connect else { return }
                do {
                    let probe = try await auth.probeDaemon()
                    failedSince = nil
                    onboarding.markConnectionConnected(latency: probe.latency)
                    if relayMode { await updateRelayIdentityWarning() }
                } catch {
                    let now = Date()
                    failedSince = failedSince ?? now
                    if now.timeIntervalSince(failedSince ?? now) >= 3 {
                        onboarding.markConnectionUnreachable(since: failedSince ?? now)
                        if relayMode { await refreshRelayDiagnostics() }
                    }
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    func continueFromConnect() {
        guard case .connected = connection else { return }
        connectionTask?.cancel()
        connectionMessage = nil
        faceIDMessage = nil
        nativeSecretEnrolledForOnboarding = false
        requestPairingCode()
    }

    private func requestPairingCode() {
        pairingTask?.cancel()
        pairingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            switch await auth.startPairing(deviceName: deviceName) {
            case .success:
                guard let details = auth.pairingDetails else {
                    connectionMessage = "The Mac returned an invalid pairing code."
                    return
                }
                #if DEBUG
                let debugExpiry = debugPairingExpirySeconds
                debugPairingExpirySeconds = nil
                let expiry = debugExpiry.map { Date().addingTimeInterval($0) } ?? details.expiresAt
                #else
                let expiry = details.expiresAt
                #endif
                onboarding.beginPairing(code: details.code, expiresAt: expiry)
                startPairingPoll()
            case .failure(let error):
                handlePairingError(error)
            }
        }
    }

    func startPairingPoll() {
        pairingTask?.cancel()
        guard onboardingStep == .pair else { return }
        pairingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, phase == .onboarding, onboardingStep == .pair else { return }
                if onboarding.isPairingExpired(at: Date()) {
                    onboarding.markPairingExpired()
                    return
                }
                switch await auth.pollPairing() {
                case .success:
                    if case .enrolling = auth.state {
                        if relayMode, let observed = transport.observedPin { relayPin = observed }
                        pairingTask = nil
                        onboarding.markPairingConfirmed(at: Date())
                        faceIDMessage = nil
                        return
                    }
                case .failure(let error):
                    if relayMode, transport.hasPinMismatch {
                        await showIdentityChanged()
                        return
                    }
                    handlePairingError(error)
                    return
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private func updateRelayIdentityWarning() async {
        guard relayMode else { return }
        let outcomes = await transport.endpointOutcomes()
        guard let mismatch = transport.configuredEndpoints.first(where: { outcomes[$0] == .pinMismatch }) else {
            relayIdentityWarning = nil
            return
        }
        guard transport.selectedEndpoint != nil else { return }
        relayIdentityWarning = RelayEndpointDiagnostic(
            id: mismatch.absoluteString,
            endpoint: mismatch,
            label: relayEndpointLabel(for: mismatch),
            status: .identityChanged
        )
    }

    private func refreshRelayDiagnostics() async {
        guard relayMode else { return }
        let outcomes = await transport.endpointOutcomes()
        var rows: [RelayEndpointDiagnostic] = []
        for endpoint in transport.configuredEndpoints {
            let status: RelayEndpointDiagnostic.Status
            if outcomes[endpoint] == .pinMismatch {
                status = .identityChanged
            } else {
                do {
                    let health = try await RelayHealthProbe(endpoint: endpoint).probe()
                    status = health.macConnected ? .relayReachable : .macNotConnected
                } catch let error as RelayHealthProbeError {
                    switch error {
                    case .localNetworkDenied: status = .localNetworkDenied
                    default: status = .notReachable
                    }
                } catch {
                    status = .notReachable
                }
            }
            rows.append(RelayEndpointDiagnostic(
                id: endpoint.absoluteString,
                endpoint: endpoint,
                label: relayEndpointLabel(for: endpoint),
                status: status
            ))
        }
        let identity = rows.contains { $0.status == .identityChanged }
        let macOffline = rows.contains { $0.status == .macNotConnected }
        let localDenied = rows.contains { $0.status == .localNetworkDenied }
        let summary: String
        if identity { summary = "Your Mac's identity changed." }
        else if macOffline { summary = "Your Mac isn't connected to the relay. Check it's awake and online." }
        else if localDenied { summary = "Allow Local Network access for cc-controller in Settings." }
        else { summary = "Can't reach the relay. Away from home? Turn on Tailscale." }
        let diagnostics = RelayDiagnostics(endpoints: rows, summary: summary)
        relayDiagnostics = diagnostics
        if rows.allSatisfy({ $0.status == .identityChanged || $0.status == .notReachable }) && identity {
            await showIdentityChanged()
        }
    }

    private func showIdentityChanged() async {
        identityChanged = true
        if relayDiagnostics == nil {
            let rows = transport.configuredEndpoints.map { endpoint in
                RelayEndpointDiagnostic(id: endpoint.absoluteString, endpoint: endpoint, label: relayEndpointLabel(for: endpoint), status: .identityChanged)
            }
            relayDiagnostics = RelayDiagnostics(endpoints: rows, summary: "Your Mac's identity changed.")
        }
    }

    func retryConnection() {
        identityChanged = false
        relayDiagnostics = nil
        transport.invalidate()
        if phase == .onboarding {
            if onboardingStep == .connect { startConnectionCheck() }
            else if onboardingStep == .pair { startPairingPoll() }
        } else if phase == .unlocked {
            store.resume()
            watchForIdentityChange()
        }
    }

    func pairAgain() async {
        connectionTask?.cancel()
        pairingTask?.cancel()
        _ = await auth.unpair()
        try? await credentials.deleteRelayPin()
        try? await credentials.deleteDeviceToken()
        try? await credentials.deleteNativeSecret()
        await store.clearLocalState()
        await transport.reconfigure(pin: nil)
        relayPin = nil
        identityChanged = false
        relayDiagnostics = nil
        relayIdentityWarning = nil
        isRelayWarningPresented = false
        onboarding = OnboardingFlowState()
        connectionMessage = nil
        faceIDMessage = nil
        nativeSecretEnrolledForOnboarding = false
        phase = .onboarding
    }

    private func watchForIdentityChange() {
        guard relayMode else { return }
        Task { @MainActor [weak self] in
            for _ in 0..<20 {
                guard let self, !identityChanged else { return }
                await updateRelayIdentityWarning()
                if await allRelayEndpointsMismatched() {
                    await showIdentityChanged()
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func allRelayEndpointsMismatched() async -> Bool {
        let outcomes = await transport.endpointOutcomes()
        guard !transport.configuredEndpoints.isEmpty else { return false }
        return transport.selectedEndpoint == nil && (transport.hasPinMismatch || transport.configuredEndpoints.allSatisfy { outcomes[$0] == .pinMismatch })
    }

    func getNewPairingCode() {
        guard case .connected = connection else {
            goBackToConnect()
            return
        }
        connectionMessage = nil
        faceIDMessage = nil
        requestPairingCode()
    }

    func copyPairingCommand() {
        guard let pairingCode else { return }
        let check = relayMode ? " \(relayPairingCheck ?? "")" : ""
        UIPasteboard.general.string = "cc-gateway pair \(pairingCode)\(check)"
        copiedPairingCommand = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.copiedPairingCommand = false
        }
    }

    func enrollAndUnlock() async {
        guard onboarding.enrollmentWindowOpen(at: Date()) else {
            goBackToConnect()
            connectionMessage = "The Face ID setup window expired. Start pairing again."
            return
        }
        let context = LAContext()
        var evaluationError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &evaluationError) else {
            if let evaluationError, let code = LAError.Code(rawValue: evaluationError.code) {
                faceIDMessage = CCKit.faceIDFailureMessage(for: .biometric(code))
                authLogger.error("enrollment biometric availability failed domain=\(evaluationError.domain, privacy: .public) errorCode=LAError \(code.rawValue, privacy: .public)")
            } else {
                let rawCode = evaluationError.map { String($0.code) } ?? "unknown"
                faceIDMessage = "Face ID did not work. Try again. (LAError \(rawCode))"
                authLogger.error("enrollment biometric availability failed domain=\(evaluationError?.domain ?? "unknown", privacy: .public) errorCode=LAError \(rawCode, privacy: .public)")
            }
            return
        }
        faceIDMessage = nil
        if !nativeSecretEnrolledForOnboarding {
            switch await auth.enroll() {
            case .success:
                nativeSecretEnrolledForOnboarding = true
            case .failure(let error):
                if error == .enrollmentWindowClosed {
                    goBackToConnect()
                    connectionMessage = "The Face ID setup window expired. Start pairing again."
                } else {
                    faceIDMessage = CCKit.faceIDFailureMessage(for: error)
                }
                return
            }
        }
        switch await auth.unlock() {
        case .success:
            onboarding.finish()
            phase = .unlocked
        case .failure(let error):
            await handleUnlockFailure(error)
        }
    }

    private func handleUnlockFailure(_ error: AuthError) async {
        switch unlockRoute(for: error) {
        case .locked(let message):
            faceIDMessage = message
            auth.lock()
            if phase == .locked {
                store.suspend()
            }
        case .rePair(let message):
            await beginRepair(message: message)
        }
    }

    private func beginRepair(message: String) async {
        connectionTask?.cancel()
        pairingTask?.cancel()
        _ = await auth.unpair()
        onboarding = OnboardingFlowState()
        onboarding.continueFromWelcome()
        connectionMessage = message
        faceIDMessage = nil
        phase = .onboarding
        startConnectionCheck()
    }

    private func handlePairingError(_ error: AuthError) {
        switch error {
        case .pairingExpired:
            onboarding.markPairingExpired()
        case .network:
            goBackToConnect()
        default:
            connectionMessage = error.localizedDescription
        }
    }

    private func transitionToLocked(suppressAutoPrompt: Bool = false) {
        auth.lock()
        store.suspend()
        hasAutoPromptedLockScreen = suppressAutoPrompt
        phase = .locked
        updateSettingsProbing()
        promptLockIfNeeded()
    }

    func lockNow() {
        guard phase == .unlocked else { return }
        isSettingsPresented = false
        transitionToLocked(suppressAutoPrompt: true)
    }

    func setLockInterval(_ interval: LockInterval) {
        lockIntervalStore.set(interval)
        lockPolicy.interval = interval
        lockTransitionPolicy.setInterval(interval)
    }

    var relayAddressesDraft: String { relayAddressesText(relayEndpoints) }

    func setRelayAddresses(_ text: String) {
        guard relayMode, let endpoints = parseRelayAddresses(text) else { return }
        UserDefaults.standard.set(text, forKey: relayDefaultsKey)
        Task { @MainActor [weak self, transport] in
            guard let self else { return }
            await transport.updateEndpoints(endpoints, pin: relayPin.flatMap { try? RelayPin($0) })
        }
    }

    func resetRelayAddresses() {
        let text = relayAddressesText(relayDefaultEndpoints)
        UserDefaults.standard.removeObject(forKey: relayDefaultsKey)
        setRelayAddresses(text)
    }

    func settingsDidAppear() {
        isSettingsVisible = true
        settings.reset()
        updateSettingsProbing()
        Task { @MainActor [weak self] in
            await self?.settings.load()
        }
    }

    func settingsDidDisappear() {
        isSettingsVisible = false
        updateSettingsProbing()
    }

    private func updateSettingsProbing() {
        settings.updateProbing(
            isVisible: isSettingsVisible,
            isUnlocked: phase == .unlocked,
            isActive: currentScenePhase == .active
        )
    }

    /// Logs out on the daemon, deletes this iPhone's Keychain items and cache, and restarts onboarding.
    func unpair() async {
        guard !isUnpairing else { return }
        isUnpairing = true
        defer { isUnpairing = false }
        connectionTask?.cancel()
        pairingTask?.cancel()
        store.suspend()
        // A failed daemon logout still leaves this iPhone unpaired: the Keychain items are deleted either way and the daemon session expires at its TTL.
        _ = await auth.unpair()
        await store.clearLocalState()
        settings.reset()
        isSettingsPresented = false
        selectedSessionID = nil
        onboarding = OnboardingFlowState()
        connectionMessage = nil
        faceIDMessage = nil
        nativeSecretEnrolledForOnboarding = false
        hasAutoPromptedLockScreen = false
        phase = .onboarding
        updateSettingsProbing()
        await updateBadgeCount(0)
    }

    func startStoreIfNeeded() {
        guard phase == .unlocked else {
            store.suspend()
            return
        }
        store.start()
        watchForIdentityChange()
        Task { @MainActor in
            await updateBadgeCount()
        }
    }

    func scenePhaseDidChange(_ scenePhase: ScenePhase) {
        #if DEBUG
        authLogger.notice("scene transition=\(String(describing: scenePhase), privacy: .public)")
        #endif
        currentScenePhase = scenePhase
        defer { updateSettingsProbing() }
        let isActive = scenePhase == .active
        let isBackgrounded = scenePhase == .background
        let shouldLock = lockTransitionPolicy.shouldLock(
            on: lockScenePhase(for: scenePhase),
            at: Date()
        )
        isPrivacyCovered = lockPolicy.shouldShowPrivacyCover(
            isActive: isActive,
            isBackgrounded: isBackgrounded,
            isLocked: phase == .locked
        )

        switch scenePhase {
        case .background:
            connectionTask?.cancel()
            pairingTask?.cancel()
            store.suspend()
        case .active:
            if phase == .onboarding {
                switch onboardingStep {
                case .connect: startConnectionCheck()
                case .pair: startPairingPoll()
                default: break
                }
                return
            }
            if phase == .locked {
                promptLockIfNeeded()
                return
            }
            guard phase == .unlocked else { return }
            if !fixtureMode, shouldLock {
                transitionToLocked()
                Task { @MainActor in
                    await updateBadgeCount(0)
                }
            } else {
                store.resume()
                watchForIdentityChange()
            }
        default:
            break
        }
    }

    private func lockScenePhase(for scenePhase: ScenePhase) -> LockScenePhase {
        switch scenePhase {
        case .active: .active
        case .inactive: .inactive
        case .background: .background
        @unknown default: .inactive
        }
    }

    private func observeSessionReplacement() {
        withObservationTracking {
            _ = store.sessions
            _ = selectedSessionID
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                reconcileSessionReplacement()
                observeSessionReplacement()
            }
        }
    }

    func reconcileSessionReplacement() {
        defer { observedSessions = store.sessions }
        guard let selectedSessionID else {
            pendingSessionReplacement = nil
            return
        }
        guard store.sessions[selectedSessionID] == nil else {
            pendingSessionReplacement = nil
            return
        }
        if pendingSessionReplacement == nil,
           observedSessions[selectedSessionID] != nil || store.previousSessionsForReplacement[selectedSessionID] != nil {
            pendingSessionReplacement = (selectedSessionID, store.previousSessionsForReplacementAt ?? Date())
        }
        guard let pendingSessionReplacement else { return }
        let previousSessions = store.previousSessionsForReplacement[pendingSessionReplacement.missingID] == nil
            ? observedSessions
            : store.previousSessionsForReplacement
        if let replacement = AppStore.replacementSessionID(
            missingSessionID: pendingSessionReplacement.missingID,
            previousSessions: previousSessions,
            currentSessions: store.sessions,
            missingAt: pendingSessionReplacement.missingAt,
            now: Date()
        ) {
            self.selectedSessionID = replacement
            self.pendingSessionReplacement = nil
        }
    }

    private func observeApprovalCount() {
        withObservationTracking {
            _ = store.approvals.count
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await updateBadgeCount()
                observeApprovalCount()
            }
        }
    }

    func requestNotificationAuthorizationAfterSessionsLoaded() async {
        guard phase == .unlocked, !fixtureMode, !notificationAuthorizationRequested, !store.sessions.isEmpty else { return }
        do {
            try await Task.sleep(for: .seconds(1))
        } catch {
            return
        }
        guard phase == .unlocked, !store.sessions.isEmpty else { return }
        requestNotificationAuthorizationIfNeeded()
    }

    private func requestNotificationAuthorizationIfNeeded() {
        guard !notificationAuthorizationRequested else { return }
        notificationAuthorizationRequested = true
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.badge])) == true else { return }
            await updateBadgeCount()
        }
    }

    private func updateBadgeCount(_ count: Int? = nil) async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized, settings.badgeSetting == .enabled else { return }
        try? await UNUserNotificationCenter.current().setBadgeCount(count ?? store.approvals.count)
    }

    #if DEBUG || CC_PERF
    private static func serverURL(arguments: [String]) -> URL? {
        guard let value = argumentValue("-CCServer", in: arguments),
              let url = URL(string: value),
              !value.isEmpty else { return nil }
        return url
    }
    #endif

    private static func launchRelayEndpointsArgument(arguments: [String]) -> String? {
        #if DEBUG || CC_PERF
        argumentValue("-CCRelayEndpoints", in: arguments)
        #else
        nil
        #endif
    }

    private static func relayEndpoints(arguments: [String]) -> [URL] {
        let value = launchRelayEndpointsArgument(arguments: arguments)
            ?? UserDefaults.standard.string(forKey: "CCRelayEndpoints")
            ?? (Bundle.main.object(forInfoDictionaryKey: "CCRelayEndpoints") as? String)
        guard let value else { return [] }
        return value.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).compactMap { URL(string: String($0)) }.filter(isValidRelayAddress)
    }

    private static func defaultRelayEndpoints() -> [URL] {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "CCRelayEndpoints") as? String else { return [] }
        return value.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).compactMap { URL(string: String($0)) }.filter(isValidRelayAddress)
    }

    #if DEBUG || CC_PERF
    private static func colorScheme(arguments: [String]) -> ColorScheme? {
        switch argumentValue("-CCColorScheme", in: arguments) {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    private static func hasFixtureArguments(arguments: [String], bearer: String) -> Bool {
        (argumentValue("-CCServer", in: arguments)?.isEmpty == false || argumentValue("-CCRelayEndpoints", in: arguments)?.isEmpty == false) && !bearer.isEmpty
    }

    private static func argumentValue(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func argumentValues(_ name: String, in arguments: [String]) -> [String] {
        arguments.indices.compactMap { index in
            guard arguments[index] == name, arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
    }

    private struct KeychainSelfTestMismatch: Error {}

    private static func runKeychainSelfTest() async -> String {
        let store = KeychainCredentialStore(service: "com.cc-controller.native-auth.self-test")
        let value = UUID().uuidString
        var step = "write"
        do {
            try await store.setDeviceToken(value)
            step = "read"
            guard try await store.getDeviceToken() == value else {
                throw KeychainSelfTestMismatch()
            }
            step = "delete"
            try await store.deleteDeviceToken()
            step = "biometry write"
            try await store.setNativeSecret(value)
            step = "biometry delete"
            try await store.deleteNativeSecret()
            return "Keychain OK"
        } catch {
            try? await store.deleteDeviceToken()
            try? await store.deleteNativeSecret()
            let status = (error as? CredentialStoreError)?.statusCode ?? -1
            return "Keychain failed: \(step) \(status)"
        }
    }
    #endif

    private static func cacheDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cc-controller", isDirectory: true)
    }
}
