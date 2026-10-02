import CCKit
import Foundation
import LocalAuthentication
import Observation
import SwiftUI
import UIKit
import UserNotifications

@MainActor @Observable
final class AppModel {
    enum Phase: Equatable {
        case onboarding
        case locked
        case unlocked
    }

    let auth: AuthSession
    let store: AppStore
    let lockPolicy: LockPolicy

    var phase: Phase
    var selectedSessionID: String?
    var isPrivacyCovered = false
    var colorScheme: ColorScheme?
    var isSettingsPresented = false
    var actionError: ActionError?
    #if DEBUG
    let debugAttachmentPaths: [URL]
    var keychainSelfTestResult: String?
    #endif
    var onboarding = OnboardingFlowState()
    var connectionMessage: String?
    var copiedPairingCommand = false
    var faceIDMessage: String?

    var onboardingStep: OnboardingStep { onboarding.step }
    var pairingCode: String? { onboarding.pairingCode }
    var pairingExpiresAt: Date? { onboarding.pairingExpiresAt }
    var connectionAddress: String { serverURL.absoluteString.replacingOccurrences(of: "http://", with: "") }
    var connection: OnboardingConnection { onboarding.connection }

    private let credentials: any CredentialStore
    private let fixtureMode: Bool
    private let debugOnboarding: Bool
    private let debugPairingExpirySeconds: TimeInterval?
    private let serverURL: URL
    private var backgroundDate: Date?
    private var connectionTask: Task<Void, Never>?
    private var pairingTask: Task<Void, Never>?
    private var notificationAuthorizationRequested = false
    private var nativeSecretEnrolledForOnboarding = false
    private var deviceName = "iPhone"

    init(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let bearer = environment["CCBearer"] ?? ""
        #if DEBUG
        let serverURL = Self.serverURL(arguments: arguments)
        let isDebugOnboarding = arguments.contains("-CCOnboarding")
        let isFixture = Self.hasFixtureArguments(arguments: arguments, bearer: bearer) && !isDebugOnboarding
        debugAttachmentPaths = Self.argumentValues("-CCAttachFile", in: arguments).map { URL(fileURLWithPath: $0) }
        #else
        let serverURL = URL(string: "http://127.0.0.1:47832")!
        let isDebugOnboarding = false
        let isFixture = false
        #endif
        self.serverURL = serverURL
        debugOnboarding = isDebugOnboarding
        #if DEBUG
        debugPairingExpirySeconds = Self.argumentValue("-CCPairingExpirySeconds", in: arguments).flatMap(TimeInterval.init)
        #else
        debugPairingExpirySeconds = nil
        #endif
        fixtureMode = isFixture

        let credentials = KeychainCredentialStore()
        self.credentials = credentials
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
            serverURL: serverURL,
            credentials: credentials,
            cacheDirectory: cacheDirectory
        )
        self.auth = auth
        self.lockPolicy = LockPolicy()
        self.phase = fixtureMode ? .unlocked : .onboarding
        #if DEBUG
        self.colorScheme = Self.colorScheme(arguments: arguments)
        #else
        self.colorScheme = nil
        #endif
        self.deviceName = UIDevice.current.name
        self.store = AppStore(
            serverURL: serverURL,
            bearerProvider: {
                #if DEBUG
                if isFixture {
                    return bearer
                }
                #endif
                return try await auth.bearer()
            },
            cacheDirectory: cacheDirectory,
            authenticationFailureHandler: {
                _ = await auth.handleUnauthorized()
            }
        )
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
            let hasSecret = (try? await credentials.getNativeSecret()) != nil
            guard phase != .unlocked else { return }
            phase = hasSecret ? .locked : .onboarding
        }
    }

    func unlock() async {
        guard case .success = await auth.unlock() else { return }
        phase = .unlocked
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
        let address = connectionAddress
        connectionTask = Task { @MainActor [weak self] in
            var failedSince: Date?
            while !Task.isCancelled {
                guard let self, phase == .onboarding, onboardingStep == .connect else { return }
                do {
                    let probe = try await auth.probeDaemon()
                    failedSince = nil
                    onboarding.markConnectionConnected()
                    if connectionMessage?.hasPrefix("Can't reach") == true {
                        connectionMessage = nil
                    }
                } catch {
                    let now = Date()
                    failedSince = failedSince ?? now
                    if now.timeIntervalSince(failedSince ?? now) >= 3 {
                        onboarding.markConnectionUnreachable(since: failedSince ?? now)
                        connectionMessage = "Can't reach the Mac yet at \(address)."
                    }
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    func continueFromConnect() {
        guard case .connected = connection else { return }
        connectionTask?.cancel()
        pairingTask?.cancel()
        connectionMessage = nil
        faceIDMessage = nil
        nativeSecretEnrolledForOnboarding = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch await auth.startPairing(deviceName: deviceName) {
            case .success:
                guard let details = auth.pairingDetails else {
                    connectionMessage = "The Mac returned an invalid pairing code."
                    return
                }
                let expiry = debugPairingExpirySeconds.map { Date().addingTimeInterval($0) } ?? details.expiresAt
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
                        pairingTask = nil
                        onboarding.markPairingConfirmed(at: Date())
                        faceIDMessage = nil
                        return
                    }
                case .failure(let error):
                    handlePairingError(error)
                    return
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    func getNewPairingCode() {
        guard case .connected = connection else {
            goBackToConnect()
            return
        }
        connectionMessage = nil
        onboarding.restartPairing()
        continueFromConnect()
    }

    func copyPairingCommand() {
        guard let pairingCode else { return }
        UIPasteboard.general.string = "cc-gateway pair \(pairingCode)"
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
            if let code = evaluationError.flatMap({ LAError.Code(rawValue: $0.code) }), code == .biometryNotEnrolled {
                faceIDMessage = "Set up Face ID in Settings to use this app"
            } else {
                faceIDMessage = "Face ID is unavailable. Try again."
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
                    faceIDMessage = faceIDFailureMessage(error)
                }
                return
            }
        }
        switch await auth.unlock() {
        case .success:
            onboarding.finish()
            phase = .unlocked
            requestNotificationAuthorizationIfNeeded()
        case .failure(let error):
            faceIDMessage = faceIDFailureMessage(error)
        }
    }

    private func handlePairingError(_ error: AuthError) {
        switch error {
        case .pairingExpired:
            onboarding.markPairingExpired()
        case .network:
            goBackToConnect()
            connectionMessage = "Can't reach the Mac yet at \(connectionAddress)."
        default:
            connectionMessage = error.localizedDescription
        }
    }

    private func faceIDFailureMessage(_ error: AuthError) -> String {
        switch error {
        case .biometric(let message): message
        case .unknownSecret: "This device secret was revoked. Start pairing again."
        default: "Face ID did not work. Try again."
        }
    }

    func startStoreIfNeeded() {
        guard phase == .unlocked else {
            store.suspend()
            return
        }
        store.start()
        Task { @MainActor in
            await updateBadgeCount()
        }
    }

    func scenePhaseDidChange(_ scenePhase: ScenePhase) {
        let isActive = scenePhase == .active
        let isBackgrounded = scenePhase == .background
        isPrivacyCovered = lockPolicy.shouldShowPrivacyCover(
            isActive: isActive,
            isBackgrounded: isBackgrounded
        )

        switch scenePhase {
        case .background:
            backgroundDate = Date()
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
            guard phase == .unlocked else { return }
            if !fixtureMode, lockPolicy.shouldLockOnForeground(after: backgroundDate, now: Date()) {
                phase = .locked
                store.suspend()
                Task { @MainActor in
                    await updateBadgeCount(0)
                    _ = await auth.logout()
                }
            } else {
                store.resume()
            }
        default:
            break
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

    #if DEBUG
    private static func serverURL(arguments: [String]) -> URL {
        guard let value = argumentValue("-CCServer", in: arguments),
              let url = URL(string: value),
              !value.isEmpty else {
            return URL(string: "http://127.0.0.1:47832")!
        }
        return url
    }

    private static func colorScheme(arguments: [String]) -> ColorScheme? {
        switch argumentValue("-CCColorScheme", in: arguments) {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    private static func hasFixtureArguments(arguments: [String], bearer: String) -> Bool {
        argumentValue("-CCServer", in: arguments)?.isEmpty == false && !bearer.isEmpty
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
