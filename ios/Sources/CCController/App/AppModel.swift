import CCKit
import Foundation
import Observation
import SwiftUI

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

    private let credentials: any CredentialStore
    private let fixtureMode: Bool
    private var backgroundDate: Date?

    init(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let serverURL = Self.serverURL(arguments: arguments)
        let bearer = environment["CCBearer"] ?? ""
        #if DEBUG
        let isFixture = Self.hasFixtureArguments(arguments: arguments, bearer: bearer)
        #else
        let isFixture = false
        #endif
        fixtureMode = isFixture

        let credentials = KeychainCredentialStore()
        self.credentials = credentials
        let cacheDirectory = Self.cacheDirectory()
        let auth = AuthSession(
            serverURL: serverURL,
            credentials: credentials,
            cacheDirectory: cacheDirectory
        )
        self.auth = auth
        self.lockPolicy = LockPolicy()
        self.phase = fixtureMode ? .unlocked : .onboarding
        self.colorScheme = Self.colorScheme(arguments: arguments)
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

        guard !fixtureMode else { return }
        Task { [weak self, credentials] in
            let hasSecret = (try? await credentials.getNativeSecret()) != nil
            guard let self, self.phase != .unlocked else { return }
            self.phase = hasSecret ? .locked : .onboarding
        }
    }

    func unlock() async {
        guard case .success = await auth.unlock() else { return }
        phase = .unlocked
    }

    func startStoreIfNeeded() {
        guard phase == .unlocked else {
            store.suspend()
            return
        }
        store.start()
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
            store.suspend()
        case .active:
            guard phase == .unlocked else { return }
            if !fixtureMode, lockPolicy.shouldLockOnForeground(after: backgroundDate, now: Date()) {
                phase = .locked
                store.suspend()
                Task { _ = await auth.logout() }
            } else {
                store.resume()
            }
        default:
            break
        }
    }

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

    private static func cacheDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cc-controller", isDirectory: true)
    }
}
