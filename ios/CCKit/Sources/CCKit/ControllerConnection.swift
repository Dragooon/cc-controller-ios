import Foundation

/// The complete, independent client stack for one controller.
@MainActor
public final class ControllerConnection {
    public let config: ControllerConfig
    public let credentials: any CredentialStore
    public let router: ConnectionRouter
    public let apiClient: APIClient
    public let auth: AuthSession
    public let store: AppStore
    public let cacheDirectory: URL

    public init(
        config: ControllerConfig,
        credentials: any CredentialStore,
        cacheRoot: URL = ControllerStorage.defaultCacheRoot(),
        session: URLSession = .shared,
        clock: any CCKitClock = SystemCCKitClock(),
        relayPin: RelayPin? = nil,
        fixtureBearer: String? = nil,
        uploadTimeout: TimeInterval = 30,
        initialTranscriptTail: Int = 100
    ) {
        self.config = config
        self.credentials = credentials
        cacheDirectory = ControllerStorage.cacheDirectory(root: cacheRoot, controllerID: config.id)

        let router: ConnectionRouter
        if let directBaseURL = config.directBaseURL {
            router = ConnectionRouter(
                baseURL: directBaseURL,
                session: session,
                relayHostID: config.relayHostID
            )
        } else {
            router = ConnectionRouter(
                endpoints: config.relayEndpoints,
                pin: relayPin,
                pinLoader: { [credentials] in
                    guard let value = try? await credentials.getRelayPin() else { return nil }
                    return try? RelayPin(value)
                },
                relayHostID: config.relayHostID
            )
        }
        self.router = router

        let apiClient = APIClient(connection: router)
        self.apiClient = apiClient
        let auth = AuthSession(
            client: AuthClient(connection: router),
            credentials: credentials,
            clock: clock,
            cacheDirectory: cacheDirectory
        )
        self.auth = auth
        self.store = AppStore(
            client: apiClient,
            bearerProvider: { [weak auth] in
                if let fixtureBearer { return fixtureBearer }
                guard let auth else { throw AuthError.locked }
                return try await auth.bearer()
            },
            clock: clock,
            cacheDirectory: cacheDirectory,
            uploadTimeout: uploadTimeout,
            authenticationFailureHandler: { [weak auth] in
                _ = await auth?.handleUnauthorized()
            },
            initialTranscriptTail: initialTranscriptTail,
            controllerInfo: ControllerInfo(
                id: config.id,
                name: config.displayName,
                kind: .claudeCode,
                capabilities: ControllerCapability.all
            )
        )
    }
}
