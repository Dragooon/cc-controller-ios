import CCKit
import Foundation
import LocalAuthentication
import Observation
import SwiftUI
import UIKit
import os
import UserNotifications

private let authLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "cc-controller",
    category: "auth"
)

@MainActor @Observable
final class AppModel {
    enum Phase: Equatable {
        case onboarding
        case locked
        case unlocked
    }

    private(set) var connections: [ControllerConnection]
    let auth: AuthSession
    private(set) var lockPolicy: LockPolicy
    let settings: SettingsStore

    var phase: Phase
    var selectedSession: SessionRef? {
        didSet {
            guard oldValue != selectedSession else { return }
            TranscriptLifecycleLog.shared.record(
                name: "selected-session",
                sessionID: selectedSession?.sessionID
            )
        }
    }
    var isPrivacyCovered = false
    var isNewSessionPresented = false
    var shouldResumeNewSession = false
    var colorScheme: ColorScheme?
    var isSettingsPresented = false
    var actionError: ActionError?
    #if DEBUG || CC_PERF
    let debugAttachmentPaths: [URL]
    var keychainSelfTestResult: String?
    #endif
    #if DEBUG
    let freezeLiveIndicators: Bool
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

    var primaryConnection: ControllerConnection { connections[0] }
    var primaryStore: AppStore { primaryConnection.store }
    private var stores: [AppStore] { connections.map(\.store) }

    func connection(for controllerID: ControllerID) -> ControllerConnection? {
        connections.first { $0.config.id == controllerID }
    }

    /// The saved config, which Settings may have edited since the connection was built.
    func config(for controllerID: ControllerID) -> ControllerConfig? {
        registry.controllers.first { $0.id == controllerID } ?? connection(for: controllerID)?.config
    }

    var controllerIDs: [ControllerID] { connections.map(\.config.id) }

    /// The multi-controller UI (list sections, controller captions, subtitle prefix) shows only with two or more.
    var hasMultipleControllers: Bool { connections.count >= 2 }

    /// The saved display name, or nil with a single controller, where names stay hidden.
    func controllerName(for controllerID: ControllerID) -> String? {
        guard hasMultipleControllers else { return nil }
        return config(for: controllerID)?.displayName ?? connection(for: controllerID)?.config.displayName
    }

    func controllerName(for store: AppStore) -> String? {
        guard let connection = connections.first(where: { $0.store === store }) else { return nil }
        return controllerName(for: connection.config.id)
    }

    /// Starts one controller's sign-in from its "Sign in needed" header. The primary goes through the app unlock;
    /// another controller signs in with its own native secret, or opens Settings when it has none.
    func signIn(controllerID: ControllerID) {
        guard let connection = connection(for: controllerID) else { return }
        if controllerID == primaryConnection.config.id {
            Task { @MainActor [weak self] in await self?.unlock() }
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard (try? await connection.credentials.hasNativeSecret()) == true else {
                self.isSettingsPresented = true
                return
            }
            switch await connection.auth.unlock(session: self.biometricSession) {
            case .success:
                connection.store.resume()
            case .failure:
                self.isSettingsPresented = true
            }
        }
    }

    var controllerRows: [SettingsControllerRow] {
        connections.map { connection in
            let config = config(for: connection.config.id) ?? connection.config
            let address = connection.router.selectedEndpoint ?? config.relayEndpoints.first ?? config.directBaseURL
            return SettingsControllerRow(
                id: config.id,
                name: config.displayName,
                kind: controllerKindText(connection.store.controllerInfo.kind),
                status: SettingsControllerStatus(connection.store.connection),
                address: controllerAddressText(address),
                isPrimary: config.id == primaryConnection.config.id
            )
        }
    }

    private let credentials: any CredentialStore
    private let registry: ControllerRegistry
    private let fixtureMode: Bool
    private let debugOnboarding: Bool
    #if DEBUG
    private var debugPairingExpirySeconds: TimeInterval?
    private let resumeNewChatAfterSeconds: TimeInterval
    #endif
    private let serverURL: URL
    private let transport: ConnectionRouter
    private var relayPin: String?
    private let relayDefaultEndpoints: [URL]
    private let relayDefaultsKey: String
    private let lockIntervalStore: LockIntervalStore
    private var lastUnlockAt: Date?
    private var lastBackgroundAt: Date?
    private var unlockExpiryTask: Task<Void, Never>?
    private var biometricSession: BiometricUnlockSession?
    private var lastSilentReloginAt: [ControllerID: Date] = [:]
    private var silentReloginInFlight: Set<ControllerID> = []
    private(set) var currentScenePhase: ScenePhase = .background
    private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var connectionPathTask: Task<Void, Never>?
    @ObservationIgnored private var connectionNoticePolicy = ConnectionNoticePolicy()
    private var pairingTask: Task<Void, Never>?
    private var notificationAuthorizationRequested = false
    private var nativeSecretEnrolledForOnboarding = false
    private var hasAutoPromptedLockScreen = false
    private var deviceName = "iPhone"
    private var isSettingsVisible = false
    private var observedSessions: [ControllerID: [String: Session]] = [:]
    /// Built lazily while a detail view renders, so it must not invalidate that view. Each store is observable itself.
    @ObservationIgnored private var controllerSettings: [ControllerID: SettingsStore] = [:]
    private var pendingSessionReplacement: [ControllerID: (missingID: String, missingAt: Date)] = [:]

    init(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        #if DEBUG
        freezeLiveIndicators = Self.argumentValue("-CCFreezeLiveIndicators", in: arguments)?.uppercased() == "YES"
        #endif
        let cacheRoot = Self.cacheDirectory()
        try? ControllerMigration.migrateLegacyCacheAndSettings(
            legacyCacheDirectory: cacheRoot,
            macCacheDirectory: ControllerStorage.cacheDirectory(root: cacheRoot, controllerID: .mac)
        )
        #if DEBUG || CC_PERF
        let bearer = environment["CCBearer"] ?? ""
        let serverOverride = Self.serverURL(arguments: arguments)
        let relayArgument = Self.argumentValue("-CCRelayEndpoints", in: arguments)
        let serverURL = serverOverride ?? URL(string: "http://127.0.0.1:47832")!
        let isDebugOnboarding = arguments.contains("-CCOnboarding")
        let isFixture = Self.hasFixtureArguments(arguments: arguments, bearer: bearer) && !isDebugOnboarding
        debugAttachmentPaths = Self.argumentValues("-CCAttachFile", in: arguments).map { URL(fileURLWithPath: $0) }
        #if DEBUG
        let launchExtraConfigs = Self.argumentValue("-CCExtraControllers", in: arguments).flatMap { try? ControllerRegistry.extraControllers(from: $0) } ?? []
        #else
        let launchExtraConfigs: [ControllerConfig] = []
        #endif
        #else
        let bearer = ""
        let serverOverride: URL? = nil
        let relayArgument: String? = nil
        let serverURL = URL(string: "http://127.0.0.1:47832")!
        let isDebugOnboarding = false
        let isFixture = false
        let launchExtraConfigs: [ControllerConfig] = []
        #endif
        #if DEBUG
        let initialTranscriptTail = isFixture
            ? Self.argumentValue("-CCFixtureInitialTranscriptTail", in: arguments).flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
            : nil
        #else
        let initialTranscriptTail: Int? = nil
        #endif
        let defaultEndpoints = Self.defaultRelayEndpoints()
        #if DEBUG || CC_PERF
        let argumentPin = Self.argumentValue("-CCRelayPin", in: arguments).flatMap { try? RelayPin($0) }
        #else
        let argumentPin: RelayPin? = nil
        #endif
        #if DEBUG
        if arguments.contains("-CCResetControllers") {
            Self.resetAddedControllers(cacheRoot: cacheRoot)
        }
        #endif
        let seed = ControllerConfig.mac(directBaseURL: URL(string: "http://127.0.0.1:47832")!)
        let registry = ControllerRegistry(
            seed: seed,
            cacheRoot: cacheRoot,
            credentialStore: { id in KeychainCredentialStore(controllerID: id) }
        )
        let legacyRelayEndpoints = UserDefaults.standard.string(forKey: ControllerStorage.namespacedKey(
            ControllerStorage.legacyRelayEndpointsKey,
            controllerID: .mac
        ))
        let resolution = ControllerConfig.resolveMac(
            saved: registry.controllers[0],
            legacyRelayEndpoints: legacyRelayEndpoints,
            bundleDefaultEndpoints: defaultEndpoints,
            hasLaunchOverride: serverOverride != nil || relayArgument != nil
        )
        var selectedConfig = resolution.config
        if resolution.shouldPersist {
            _ = registry.update(selectedConfig)
        } else if selectedConfig != registry.controllers[0] {
            _ = registry.update(selectedConfig, persist: false)
        }
        if resolution.shouldRemoveLegacyRelayEndpoints {
            UserDefaults.standard.removeObject(forKey: ControllerStorage.namespacedKey(
                ControllerStorage.legacyRelayEndpointsKey,
                controllerID: .mac
            ))
        }
        if let serverOverride {
            selectedConfig.directBaseURL = serverOverride
            selectedConfig.relayEndpoints = []
        } else if let relayArgument {
            selectedConfig.directBaseURL = nil
            selectedConfig.relayEndpoints = ControllerConfig.relayEndpoints(from: relayArgument)
        }
        if selectedConfig != registry.controllers[0] {
            _ = registry.update(selectedConfig, persist: false)
        }
        let extraConfigs = launchExtraConfigs.filter { config in
            !registry.controllers.contains { $0.id == config.id }
        }
        let configs = registry.controllers + extraConfigs
        let primaryCredentials = KeychainCredentialStore(controllerID: selectedConfig.id)
        let connections = configs.map { config in
            let credentials = config.id == selectedConfig.id
                ? primaryCredentials
                : KeychainCredentialStore(controllerID: config.id)
            let fixtureBearer: String?
            #if DEBUG || CC_PERF
            fixtureBearer = config.id == selectedConfig.id
                ? (isFixture ? bearer : nil)
                : environment["CCExtraControllerBearer_\(config.id.rawValue)"]
            #else
            fixtureBearer = nil
            #endif
            return ControllerConnection(
                config: config,
                credentials: credentials,
                cacheRoot: cacheRoot,
                relayPin: config.id == selectedConfig.id ? argumentPin : nil,
                fixtureBearer: fixtureBearer,
                initialTranscriptTail: initialTranscriptTail ?? 100
            )
        }
        let controller = connections[0]
        let credentials = primaryCredentials
        #if os(iOS)
        try? KeychainCredentialStore().moveLegacyItems(to: credentials)
        #endif
        self.registry = registry
        self.connections = connections
        self.credentials = credentials
        self.serverURL = selectedConfig.directBaseURL ?? serverURL
        self.transport = controller.router
        self.relayDefaultsKey = ControllerStorage.namespacedKey(
            ControllerStorage.legacyRelayEndpointsKey,
            controllerID: selectedConfig.id
        )
        self.relayPin = argumentPin?.value
        self.relayDefaultEndpoints = defaultEndpoints
        let lockIntervalStore = LockIntervalStore()
        self.lockIntervalStore = lockIntervalStore
        debugOnboarding = isDebugOnboarding
        #if DEBUG
        debugPairingExpirySeconds = Self.argumentValue("-CCPairingExpirySeconds", in: arguments).flatMap(TimeInterval.init)
        resumeNewChatAfterSeconds = Self.argumentValue("-CCResumeNewChatAfterSeconds", in: arguments)
            .flatMap(TimeInterval.init)
            .map { max(0, $0) }
            ?? ResumeNewChatPolicy.defaultThreshold
        #endif
        fixtureMode = isFixture
        #if DEBUG || CC_PERF
        selectedSession = Self.argumentValue("-CCSession", in: arguments).flatMap {
            guard let reference = SessionRef.parse($0, primaryControllerID: selectedConfig.id),
                  connections.contains(where: { $0.config.id == reference.controllerID }) else { return nil }
            return reference
        }
        #else
        selectedSession = nil
        #endif

        #if DEBUG
        let controllerCacheDirectory = ControllerStorage.cacheDirectory(root: cacheRoot, controllerID: selectedConfig.id)
        if arguments.contains("-CCResetCache"), FileManager.default.fileExists(atPath: controllerCacheDirectory.path) {
            do {
                try FileManager.default.removeItem(at: controllerCacheDirectory)
            } catch {
                assertionFailure("Could not reset fixture cache: \(error)")
            }
        }
        #endif
        let auth = controller.auth
        self.auth = auth
        #if DEBUG
        let lockInterval = Self.argumentValue("-CCLockInterval", in: arguments)
            .flatMap(TimeInterval.init)
            .map(LockInterval.custom) ?? lockIntervalStore.interval
        let maxUnlockAge = Self.argumentValue("-CCMaxUnlockAge", in: arguments)
            .flatMap(TimeInterval.init) ?? 60 * 60
        let lockPolicy = LockPolicy(interval: lockInterval, maxUnlockAge: maxUnlockAge)
        let probeInterval = Self.argumentValue("-CCProbeInterval", in: arguments)
            .flatMap(TimeInterval.init)
            .map { Duration.seconds($0) } ?? .seconds(2)
        self.lockPolicy = lockPolicy
        #else
        let lockPolicy = LockPolicy(interval: lockIntervalStore.interval)
        let probeInterval: Duration = .seconds(2)
        self.lockPolicy = lockPolicy
        #endif
        self.phase = fixtureMode ? .unlocked : .onboarding
        #if DEBUG
        self.colorScheme = Self.colorScheme(arguments: arguments)
        #else
        self.colorScheme = nil
        #endif
        self.deviceName = UIDevice.current.name
        let store = controller.store
        self.settings = SettingsStore(
            probe: { try await auth.probeDaemon(timeout: 5) },
            whoAmI: { try await store.whoAmI() },
            devices: { try await store.pairedDevices() },
            conversations: { try await store.peerConversations() },
            revokeConversation: { id in try await store.revokePeerConversation(id: id) },
            interval: probeInterval
        )
        for connection in connections {
            let controllerID = connection.config.id
            connection.store.setAuthenticationFailureHandler { [weak self] in
                await self?.handleAuthenticationFailure(controllerID: controllerID)
            }
        }
        observedSessions = Dictionary(uniqueKeysWithValues: connections.map { ($0.config.id, $0.store.sessions) })
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
        Task { @MainActor [weak self, credentials] in
            guard let self else { return }
            if debugOnboarding {
                try? await credentials.deleteDeviceToken()
                try? await credentials.deleteNativeSecret()
                try? await credentials.deleteLastUnlockAt()
                try? await credentials.deleteLastBackgroundAt()
                try? await credentials.deleteSessionBearer()
                lastUnlockAt = nil
                lastBackgroundAt = nil
                onboarding = OnboardingFlowState()
                phase = .onboarding
                return
            }

            lastUnlockAt = try? await credentials.getLastUnlockAt()
            lastBackgroundAt = try? await credentials.getLastBackgroundAt()
            let hasSecret = (try? await credentials.hasNativeSecret()) == true
            let hasToken = (try? await credentials.getDeviceToken()) != nil
            guard !fixtureMode else {
                if let lastUnlockAt,
                   lockPolicy.shouldLockOnColdLaunch(lastUnlockAt: lastUnlockAt, lastBackgroundAt: lastBackgroundAt, now: Date()) {
                    transitionToLocked()
                } else {
                    phase = .unlocked
                    scheduleUnlockExpiryIfNeeded()
                }
                return
            }

            guard phase != .unlocked else { return }
            if transport.mode == .relay {
                let hasPin = (try? await credentials.getRelayPin()).flatMap { try? RelayPin($0) } != nil
                if relayCredentialPolicy(hasPin: hasPin, hasCredentials: hasSecret || hasToken) == .clearAndPairAgain {
                    try? await credentials.deleteDeviceToken()
                    try? await credentials.deleteNativeSecret()
                    try? await credentials.deleteLastUnlockAt()
                    try? await credentials.deleteLastBackgroundAt()
                    try? await credentials.deleteSessionBearer()
                    onboarding = OnboardingFlowState()
                    onboarding.continueFromWelcome()
                    connectionMessage = "Pair this iPhone again to connect through the relay."
                    phase = .onboarding
                    startConnectionCheck()
                    return
                }
            }
            guard hasSecret else {
                phase = .onboarding
                return
            }
            if lockPolicy.shouldLockOnColdLaunch(
                lastUnlockAt: lastUnlockAt,
                lastBackgroundAt: lastBackgroundAt,
                now: Date()
            ) {
                transitionToLocked()
            } else if await restoreStoredBearers() {
                phase = .unlocked
                startAuthenticatedStores()
                scheduleUnlockExpiryIfNeeded()
            } else {
                transitionToLocked()
            }
        }
    }

    func unlock() async {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }

        let session = biometricSession ?? BiometricUnlockSession()
        biometricSession = session
        let result = await auth.unlock(session: session)
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
            await recordSuccessfulUnlock()
            await unlockOtherControllers(session: session)
        case .failure(let error):
            invalidateBiometricSession()
            await handleUnlockFailure(error)
        }
    }

    /// Signs in to every paired controller after the primary. The shared biometric session authorizes each
    /// native-secret read during app unlock; one controller that fails stays at "Sign in needed".
    private func unlockOtherControllers(session: BiometricUnlockSession? = nil) async {
        guard !fixtureMode else { return }
        let session = session ?? biometricSession
        for connection in connections.dropFirst() {
            guard phase == .unlocked else { return }
            guard (try? await connection.credentials.hasNativeSecret()) == true else { continue }
            if case .success = await connection.auth.unlock(session: session) {
                connection.store.resume()
            }
        }
    }

    private func restoreStoredBearers() async -> Bool {
        var primaryRestored = false
        for connection in connections {
            let stored = try? await connection.credentials.getSessionBearer()
            guard let stored,
                  connection.auth.restore(token: stored.token, expiresAt: stored.expiresAt) else {
                try? await connection.credentials.deleteSessionBearer()
                if connection.config.id == primaryConnection.config.id { return false }
                continue
            }
            if connection.config.id == primaryConnection.config.id {
                primaryRestored = true
            }
        }
        return primaryRestored
    }

    private func handleAuthenticationFailure(controllerID: ControllerID) async {
        guard let connection = connection(for: controllerID) else { return }
        try? await connection.credentials.deleteSessionBearer()
        connection.auth.lock()
        guard await attemptSilentRelogin(for: connection) else {
            connection.store.suspend()
            if controllerID == primaryConnection.config.id {
                transitionToLocked()
            }
            return
        }
    }

    private func attemptSilentRelogin(for connection: ControllerConnection) async -> Bool {
        guard phase == .unlocked, let session = biometricSession else { return false }
        let controllerID = connection.config.id
        if silentReloginInFlight.contains(controllerID) { return true }
        let now = Date()
        if let lastAttempt = lastSilentReloginAt[controllerID], now.timeIntervalSince(lastAttempt) < 30 {
            if case .unlocked = connection.auth.state { return true }
            return false
        }
        lastSilentReloginAt[controllerID] = now
        silentReloginInFlight.insert(controllerID)
        defer { silentReloginInFlight.remove(controllerID) }
        guard case .success = await connection.auth.unlock(session: session) else { return false }
        connection.store.resume()
        TranscriptLifecycleLog.shared.record(name: "silent-relogin", detail: controllerID.rawValue)
        return true
    }

    private func isAuthenticated(_ connection: ControllerConnection) -> Bool {
        if fixtureMode { return true }
        if case .unlocked = connection.auth.state { return true }
        return false
    }

    private func resumeAuthenticatedStores() {
        for connection in connections where isAuthenticated(connection) {
            connection.store.resume()
        }
    }

    private func startAuthenticatedStores() {
        for connection in connections where isAuthenticated(connection) {
            connection.store.start()
        }
    }

    private func recordSuccessfulUnlock() async {
        let now = Date()
        lastUnlockAt = now
        lastBackgroundAt = nil
        do {
            try await credentials.setLastUnlockAt(now)
            try await credentials.deleteLastBackgroundAt()
        } catch {
            authLogger.error("Could not persist unlock timestamps: \(error.localizedDescription, privacy: .public)")
        }
        scheduleUnlockExpiryIfNeeded()
    }

    private func recordBackground(at date: Date) {
        lastBackgroundAt = date
        Task { @MainActor [weak self, credentials] in
            do {
                try await credentials.setLastBackgroundAt(date)
            } catch {
                authLogger.error("Could not persist background timestamp: \(error.localizedDescription, privacy: .public)")
            }
            self?.unlockExpiryTask?.cancel()
        }
    }

    private func clearBackgroundTimestamp() {
        guard lastBackgroundAt != nil else { return }
        lastBackgroundAt = nil
        Task { @MainActor [weak self, credentials] in
            try? await credentials.deleteLastBackgroundAt()
            self?.scheduleUnlockExpiryIfNeeded()
        }
    }

    private func scheduleUnlockExpiryIfNeeded() {
        unlockExpiryTask?.cancel()
        unlockExpiryTask = nil
        guard !fixtureMode, phase == .unlocked, currentScenePhase == .active,
              let expiry = lockPolicy.unlockExpiryDate(lastUnlockAt: lastUnlockAt) else { return }
        let delay = max(0, expiry.timeIntervalSinceNow)
        unlockExpiryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self, phase == .unlocked, currentScenePhase == .active,
                  lockPolicy.shouldLockOnForeground(lastUnlockAt: lastUnlockAt, after: nil, now: Date()) else { return }
            transitionToLocked()
            await updateBadgeCount(0)
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
        connectionPathTask?.cancel()
        connectionPathTask = nil
        onboarding = OnboardingFlowState()
        connectionMessage = nil
    }

    func goBackToConnect() {
        pairingTask?.cancel()
        connectionPathTask?.cancel()
        connectionPathTask = nil
        onboarding.restartPairing()
        connectionMessage = nil
        faceIDMessage = nil
        startConnectionCheck()
    }

    func startConnectionCheck() {
        connectionTask?.cancel()
        connectionPathTask?.cancel()
        connectionPathTask = nil
        guard onboardingStep == .connect else { return }
        connectionNoticePolicy.beginGracePeriod()
        onboarding.markConnectionChecking()
        connectionPathTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await _ in self.transport.pathChangeEvents() {
                guard self.phase == .onboarding, self.onboardingStep == .connect else { return }
                self.connectionNoticePolicy.beginGracePeriod()
            }
        }
        connectionTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, phase == .onboarding, onboardingStep == .connect else { return }
                do {
                    let probe = try await auth.probeDaemon()
                    connectionNoticePolicy.markSuccess()
                    onboarding.markConnectionConnected(latency: probe.latency)
                    if relayMode { await updateRelayIdentityWarning() }
                } catch {
                    switch connectionNoticePolicy.failureDecision() {
                    case .suppress:
                        onboarding.markConnectionChecking()
                    case .show:
                        onboarding.markConnectionUnreachable(since: Date())
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
        else if localDenied { summary = "Allow Local Network access for Code in Settings." }
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
            resumeAuthenticatedStores()
            watchForIdentityChange()
        }
    }

    func pairAgain() async {
        invalidateBiometricSession()
        connectionTask?.cancel()
        pairingTask?.cancel()
        _ = await auth.unpair()
        try? await credentials.deleteRelayPin()
        try? await credentials.deleteDeviceToken()
        try? await credentials.deleteNativeSecret()
        try? await credentials.deleteLastUnlockAt()
        try? await credentials.deleteLastBackgroundAt()
        try? await credentials.deleteSessionBearer()
        lastUnlockAt = nil
        lastBackgroundAt = nil
        await primaryStore.clearLocalState()
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
            await recordSuccessfulUnlock()
            await unlockOtherControllers()
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
                stores.forEach { $0.suspend() }
            }
        case .rePair(let message):
            await beginRepair(message: message)
        }
    }

    private func beginRepair(message: String) async {
        invalidateBiometricSession()
        connectionTask?.cancel()
        pairingTask?.cancel()
        await auth.prepareForRepair()
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

    private func invalidateBiometricSession() {
        biometricSession?.invalidate()
        biometricSession = nil
        lastSilentReloginAt.removeAll()
        silentReloginInFlight.removeAll()
    }

    private func transitionToLocked(suppressAutoPrompt: Bool = false) {
        invalidateBiometricSession()
        unlockExpiryTask?.cancel()
        unlockExpiryTask = nil
        connections.forEach { $0.auth.lock() }
        stores.forEach { $0.suspend() }
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
    }

    var relayAddressesDraft: String { relayAddressesText(relayEndpoints) }

    func setRelayAddresses(_ text: String) {
        guard relayMode, let endpoints = parseRelayAddresses(text) else { return }
        var config = registry.controllers[0]
        config.directBaseURL = nil
        config.relayEndpoints = endpoints
        _ = registry.update(config)
        UserDefaults.standard.removeObject(forKey: relayDefaultsKey)
        Task { @MainActor [transport, relayPin] in
            await transport.updateEndpoints(endpoints, pin: relayPin.flatMap { try? RelayPin($0) })
        }
    }

    func resetRelayAddresses() {
        setRelayAddresses(relayAddressesText(relayDefaultEndpoints))
    }

    func relayAddresses(for controllerID: ControllerID) -> String {
        guard controllerID != primaryConnection.config.id else { return relayAddressesDraft }
        return relayAddressesText(config(for: controllerID)?.relayEndpoints ?? [])
    }

    func setRelayAddresses(_ text: String, for controllerID: ControllerID) {
        guard controllerID != primaryConnection.config.id else {
            setRelayAddresses(text)
            return
        }
        guard let connection = connection(for: controllerID),
              var config = config(for: controllerID),
              config.directBaseURL == nil,
              let endpoints = parseRelayAddresses(text) else { return }
        config.relayEndpoints = endpoints
        _ = registry.update(config)
        Task { @MainActor in
            let pin = (try? await connection.credentials.getRelayPin()).flatMap { try? RelayPin($0) }
            await connection.router.updateEndpoints(endpoints, pin: pin)
        }
    }

    func relayPinGrouped(for controllerID: ControllerID) async -> String? {
        guard controllerID != primaryConnection.config.id else { return relayPinGrouped }
        guard let connection = connection(for: controllerID) else { return nil }
        let saved = try? await connection.credentials.getRelayPin()
        return (saved ?? connection.router.observedPin).flatMap { (try? RelayPin($0))?.grouped }
    }

    /// The primary uses the Settings screen's own store; every other controller gets one for its detail screen.
    func settingsStore(for controllerID: ControllerID) -> SettingsStore? {
        guard controllerID != primaryConnection.config.id else { return settings }
        if let existing = controllerSettings[controllerID] { return existing }
        guard let connection = connection(for: controllerID) else { return nil }
        let auth = connection.auth
        let store = connection.store
        let settingsStore = SettingsStore(
            probe: { try await auth.probeDaemon(timeout: 5) },
            whoAmI: { try await store.whoAmI() },
            devices: { try await store.pairedDevices() },
            conversations: { try await store.peerConversations() },
            revokeConversation: { id in try await store.revokePeerConversation(id: id) }
        )
        controllerSettings[controllerID] = settingsStore
        return settingsStore
    }

    func makeAddControllerModel() -> AddControllerModel {
        let cacheRoot = Self.cacheDirectory()
        return AddControllerModel(
            deviceName: deviceName,
            existingIDs: { [weak self] in self?.controllerIDs ?? [] },
            makeConnection: { config in
                ControllerConnection(
                    config: config,
                    credentials: KeychainCredentialStore(controllerID: config.id),
                    cacheRoot: cacheRoot
                )
            },
            adopt: { [weak self] connection in self?.adoptController(connection) }
        )
    }

    /// Keeps a controller that Add controller paired and signed in to: saves it and starts its connection.
    func adoptController(_ connection: ControllerConnection) {
        guard self.connection(for: connection.config.id) == nil else { return }
        _ = registry.add(connection.config)
        connections.append(connection)
        let controllerID = connection.config.id
        connection.store.setAuthenticationFailureHandler { [weak self] in
            await self?.handleAuthenticationFailure(controllerID: controllerID)
        }
        observedSessions[connection.config.id] = connection.store.sessions
        if phase == .unlocked, isAuthenticated(connection) {
            connection.store.start()
        }
    }

    /// Signs out of a controller other than the primary and deletes its Keychain items, caches and settings.
    func removeController(_ controllerID: ControllerID) async {
        guard controllerID != primaryConnection.config.id, let connection = connection(for: controllerID) else { return }
        invalidateBiometricSession()
        connection.store.suspend()
        // As with unpair, a failed logout still removes the controller: its credentials are deleted either way.
        _ = await connection.auth.unpair()
        await connection.store.clearLocalState()
        await registry.remove(controllerID)
        connections.removeAll { $0.config.id == controllerID }
        controllerSettings.removeValue(forKey: controllerID)
        observedSessions.removeValue(forKey: controllerID)
        pendingSessionReplacement.removeValue(forKey: controllerID)
        if selectedSession?.controllerID == controllerID {
            selectedSession = nil
        }
        await updateBadgeCount()
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
        invalidateBiometricSession()
        isUnpairing = true
        defer { isUnpairing = false }
        connectionTask?.cancel()
        pairingTask?.cancel()
        stores.forEach { $0.suspend() }
        // A failed daemon logout still leaves this iPhone unpaired: the Keychain items are deleted either way and the daemon session expires at its TTL.
        _ = await auth.unpair()
        await primaryStore.clearLocalState()
        settings.reset()
        isSettingsPresented = false
        selectedSession = nil
        onboarding = OnboardingFlowState()
        connectionMessage = nil
        faceIDMessage = nil
        nativeSecretEnrolledForOnboarding = false
        hasAutoPromptedLockScreen = false
        lastUnlockAt = nil
        lastBackgroundAt = nil
        unlockExpiryTask?.cancel()
        unlockExpiryTask = nil
        phase = .onboarding
        updateSettingsProbing()
        await updateBadgeCount(0)
    }

    func startStoreIfNeeded() {
        guard phase == .unlocked else {
            stores.forEach { $0.suspend() }
            return
        }
        startAuthenticatedStores()
        watchForIdentityChange()
        Task { @MainActor in
            await updateBadgeCount()
        }
    }

    func scenePhaseDidChange(_ scenePhase: ScenePhase) {
        TranscriptLifecycleLog.shared.record(name: "scene-phase", detail: String(describing: scenePhase))
        #if DEBUG
        authLogger.notice("scene transition=\(String(describing: scenePhase), privacy: .public)")
        #endif
        currentScenePhase = scenePhase
        defer { updateSettingsProbing() }
        let now = Date()
        let isActive = scenePhase == .active
        let isBackgrounded = scenePhase == .background
        isPrivacyCovered = lockPolicy.shouldShowPrivacyCover(
            isActive: isActive,
            isBackgrounded: isBackgrounded,
            isLocked: phase == .locked
        )

        switch scenePhase {
        case .background:
            recordBackground(at: now)
            unlockExpiryTask?.cancel()
            connectionTask?.cancel()
            connectionPathTask?.cancel()
            connectionPathTask = nil
            pairingTask?.cancel()
            stores.forEach { $0.suspend() }
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
            #if DEBUG
            let resumeNewChatThreshold = resumeNewChatAfterSeconds
            #else
            let resumeNewChatThreshold = ResumeNewChatPolicy.defaultThreshold
            #endif
            if ResumeNewChatPolicy.shouldResume(
                backgroundAt: lastBackgroundAt,
                now: now,
                threshold: resumeNewChatThreshold,
                hasPendingApprovals: stores.contains { !$0.approvals.isEmpty },
                isOnNewChat: isNewSessionPresented,
                isPaired: phase == .unlocked
            ) {
                shouldResumeNewSession = true
            }
            let shouldLock = (!fixtureMode || lastUnlockAt != nil) && lockPolicy.shouldLockOnForeground(
                lastUnlockAt: lastUnlockAt,
                after: lastBackgroundAt,
                now: now
            )
            if shouldLock {
                transitionToLocked()
                Task { @MainActor in
                    await updateBadgeCount(0)
                }
            } else {
                clearBackgroundTimestamp()
                resumeAuthenticatedStores()
                stores.forEach { $0.resyncOpenTranscripts() }
                watchForIdentityChange()
                scheduleUnlockExpiryIfNeeded()
            }
        default:
            break
        }
    }

    private func observeSessionReplacement() {
        withObservationTracking {
            for connection in connections { _ = connection.store.sessions }
            _ = selectedSession
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                reconcileSessionReplacement()
                observeSessionReplacement()
            }
        }
    }

    func reconcileSessionReplacement() {
        defer {
            observedSessions = Dictionary(uniqueKeysWithValues: connections.map { ($0.config.id, $0.store.sessions) })
        }
        for connection in connections {
            let controllerID = connection.config.id
            guard selectedSession?.controllerID == controllerID,
                  let selectedSessionID = selectedSession?.sessionID else { continue }
            let store = connection.store
            guard store.sessions[selectedSessionID] == nil else {
                pendingSessionReplacement.removeValue(forKey: controllerID)
                continue
            }
            if pendingSessionReplacement[controllerID] == nil,
               observedSessions[controllerID]?[selectedSessionID] != nil || store.previousSessionsForReplacement[selectedSessionID] != nil {
                pendingSessionReplacement[controllerID] = (selectedSessionID, store.previousSessionsForReplacementAt ?? Date())
            }
            guard let pending = pendingSessionReplacement[controllerID] else { continue }
            let previousSessions = store.previousSessionsForReplacement[pending.missingID] == nil
                ? observedSessions[controllerID, default: [:]]
                : store.previousSessionsForReplacement
            if let replacement = AppStore.replacementSessionID(
                missingSessionID: pending.missingID,
                previousSessions: previousSessions,
                currentSessions: store.sessions,
                missingAt: pending.missingAt,
                now: Date()
            ) {
                selectedSession = SessionRef(controllerID: controllerID, sessionID: replacement)
                pendingSessionReplacement.removeValue(forKey: controllerID)
            }
        }
    }

    private func observeApprovalCount() {
        withObservationTracking {
            for connection in connections { _ = connection.store.approvals.count }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await updateBadgeCount()
                observeApprovalCount()
            }
        }
    }

    func requestNotificationAuthorizationAfterSessionsLoaded() async {
        guard phase == .unlocked, !fixtureMode, !notificationAuthorizationRequested,
              stores.contains(where: { !$0.sessions.isEmpty }) else { return }
        do {
            try await Task.sleep(for: .seconds(1))
        } catch {
            return
        }
        guard phase == .unlocked, stores.contains(where: { !$0.sessions.isEmpty }) else { return }
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
        let approvalCount = stores.reduce(0) { $0 + $1.approvals.count }
        try? await UNUserNotificationCenter.current().setBadgeCount(count ?? approvalCount)
    }

    #if DEBUG || CC_PERF
    private static func serverURL(arguments: [String]) -> URL? {
        guard let value = argumentValue("-CCServer", in: arguments),
              let url = URL(string: value),
              !value.isEmpty else { return nil }
        return url
    }
    #endif

    private static func defaultRelayEndpoints() -> [URL] {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "CCRelayEndpoints") as? String else { return [] }
        return ControllerConfig.relayEndpoints(from: value)
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

    /// Test-only: forgets every saved controller except the Mac, with its Keychain items and cache.
    private static func resetAddedControllers(cacheRoot: URL, defaults: UserDefaults = .standard) {
        let key = ControllerRegistry.defaultDefaultsKey
        let saved = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([ControllerConfig].self, from: $0) } ?? []
        let kept = saved.filter { $0.id == .mac }
        for config in saved where config.id != .mac {
            try? FileManager.default.removeItem(at: ControllerStorage.cacheDirectory(root: cacheRoot, controllerID: config.id))
            defaults.removeObject(forKey: ControllerStorage.namespacedKey(ControllerStorage.legacyRelayEndpointsKey, controllerID: config.id))
            let credentials = KeychainCredentialStore(controllerID: config.id)
            Task { try? await credentials.deleteAll() }
        }
        if kept.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(kept) {
            defaults.set(data, forKey: key)
        }
    }

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
