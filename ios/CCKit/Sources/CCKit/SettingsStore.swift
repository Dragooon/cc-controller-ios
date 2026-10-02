import Foundation
import Observation

/// Live state behind the Settings sheet: the latency probe loop, Test connection, and the daemon's device records.
@MainActor @Observable
public final class SettingsStore {
    public private(set) var latency: SettingsLatency = .checking
    public private(set) var connectionTest: SettingsConnectionTest?
    public private(set) var thisDevice: SettingsLoad<SettingsThisDevice> = .loading
    public private(set) var pairedDevices: SettingsLoad<[SettingsPairedDeviceRow]> = .loading
    public private(set) var isProbing = false

    @ObservationIgnored private let probe: @MainActor () async throws -> DaemonProbe
    @ObservationIgnored private let whoAmI: @MainActor () async throws -> WhoAmI
    @ObservationIgnored private let devices: @MainActor () async throws -> [Device]
    @ObservationIgnored private let clock: any CCKitClock
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private var probeTask: Task<Void, Never>?

    public init(
        probe: @escaping @MainActor () async throws -> DaemonProbe,
        whoAmI: @escaping @MainActor () async throws -> WhoAmI,
        devices: @escaping @MainActor () async throws -> [Device],
        clock: any CCKitClock = SystemCCKitClock(),
        interval: Duration = .seconds(2)
    ) {
        self.probe = probe
        self.whoAmI = whoAmI
        self.devices = devices
        self.clock = clock
        self.interval = interval
    }

    /// Probes only while the sheet is on screen, the app is active, and the app is unlocked.
    public func updateProbing(isVisible: Bool, isUnlocked: Bool, isActive: Bool) {
        let shouldProbe = isVisible && isUnlocked && isActive
        guard shouldProbe != isProbing else { return }
        isProbing = shouldProbe
        probeTask?.cancel()
        probeTask = nil
        guard shouldProbe else { return }
        probeTask = Task { [weak self] in
            await self?.runProbeLoop()
        }
    }

    public func testConnection() async {
        guard connectionTest != .testing else { return }
        connectionTest = .testing
        let measured = await measure()
        let now = clock.now
        guard let measured else {
            latency = .unreachable
            connectionTest = .unreachable(at: now)
            return
        }
        latency = .reachable(measured)
        connectionTest = .reachable(latency: measured, at: now)
    }

    public func load() async {
        async let identity: Void = loadThisDevice()
        async let list: Void = loadPairedDevices()
        _ = await (identity, list)
    }

    public func loadThisDevice() async {
        thisDevice = .loading
        do {
            thisDevice = .loaded(SettingsThisDevice(whoAmI: try await whoAmI()))
        } catch {
            thisDevice = .failed(error.localizedDescription)
        }
    }

    public func loadPairedDevices() async {
        pairedDevices = .loading
        do {
            pairedDevices = .loaded(settingsPairedDeviceRows(try await devices()))
        } catch {
            pairedDevices = .failed(error.localizedDescription)
        }
    }

    public func reset() {
        updateProbing(isVisible: false, isUnlocked: false, isActive: false)
        latency = .checking
        connectionTest = nil
        thisDevice = .loading
        pairedDevices = .loading
    }

    private func runProbeLoop() async {
        while !Task.isCancelled {
            let measured = await measure()
            // A cancelled request fails like an unreachable Mac, so its result must not reach the screen.
            guard !Task.isCancelled else { return }
            latency = measured.map(SettingsLatency.reachable) ?? .unreachable
            do { try await clock.sleep(for: interval) } catch { return }
        }
    }

    private func measure() async -> Duration? {
        do {
            return try await probe().latency
        } catch {
            return nil
        }
    }
}
