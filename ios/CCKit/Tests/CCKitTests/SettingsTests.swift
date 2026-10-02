import Foundation
import XCTest
@testable import CCKit

final class SettingsFormattingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testAppVersionCombinesVersionAndBuildAndNamesMissingParts() {
        XCTAssertEqual(appVersionText(version: "0.1.0", build: "1"), "0.1.0 (1)")
        XCTAssertEqual(appVersionText(version: "0.1.0", build: " "), "0.1.0")
        XCTAssertEqual(appVersionText(version: nil, build: "7"), "Build 7")
        XCTAssertEqual(appVersionText(version: nil, build: nil), "Unknown")
    }

    func testDaemonVersionShortensTheCommitAndNamesMissingParts() {
        XCTAssertEqual(daemonVersionText(DaemonInfo(version: "0.1.0", commit: "b961f05")), "0.1.0 (b961f05)")
        XCTAssertEqual(daemonVersionText(DaemonInfo(version: "0.1.0", commit: "b961f05e1c2d3a4b5c6d7e8f9a0b1c2d3e4f5a6b")), "0.1.0 (b961f05)")
        XCTAssertEqual(daemonVersionText(DaemonInfo(version: "0.1.0", commit: nil)), "0.1.0")
        XCTAssertEqual(daemonVersionText(DaemonInfo(version: "", commit: "b961f05")), "Unknown version (b961f05)")
        XCTAssertEqual(daemonVersionText(DaemonInfo()), "Unknown")
        XCTAssertEqual(daemonVersionText(nil), "Unavailable")
    }

    func testAPIVersionFallsBackWhenBootstrapIsMissing() {
        XCTAssertEqual(apiVersionText(2), "2")
        XCTAssertEqual(apiVersionText(nil), "Unavailable")
    }

    func testPairedDateUsesTheAbbreviatedDateInTheGivenLocale() {
        let date = Date(timeIntervalSince1970: 1_790_726_400)
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(pairedDateText(date, locale: Locale(identifier: "en_AU"), timeZone: utc), "30 Sep 2026")
        XCTAssertEqual(pairedDateText(date, locale: Locale(identifier: "en_US"), timeZone: utc), "Sep 30, 2026")
        XCTAssertEqual(pairedDateText(nil), "Unknown")
    }

    func testSessionExpiryRoundsDownAndCoversEveryRange() {
        XCTAssertEqual(sessionExpiryText(nil, now: now), "Unknown")
        XCTAssertEqual(sessionExpiryText(now.addingTimeInterval(-1), now: now), "Expired")
        XCTAssertEqual(sessionExpiryText(now, now: now), "Expired")
        XCTAssertEqual(sessionExpiryText(now.addingTimeInterval(59), now: now), "in under a minute")
        XCTAssertEqual(sessionExpiryText(now.addingTimeInterval(25 * 60 + 30), now: now), "in 25 min")
        XCTAssertEqual(sessionExpiryText(now.addingTimeInterval(59 * 60 + 59), now: now), "in 59 min")
        XCTAssertEqual(sessionExpiryText(now.addingTimeInterval(60 * 60), now: now), "in 1 h")
        XCTAssertEqual(sessionExpiryText(now.addingTimeInterval(12 * 60 * 60 - 1), now: now), "in 11 h")
    }

    func testLastSeenCoversJustNowMinutesHoursAndDays() {
        XCTAssertEqual(lastSeenText(nil, now: now), "Not seen yet")
        XCTAssertEqual(lastSeenText(now.addingTimeInterval(5), now: now), "Last seen just now")
        XCTAssertEqual(lastSeenText(now.addingTimeInterval(-59), now: now), "Last seen just now")
        XCTAssertEqual(lastSeenText(now.addingTimeInterval(-5 * 60), now: now), "Last seen 5 min ago")
        XCTAssertEqual(lastSeenText(now.addingTimeInterval(-3 * 60 * 60), now: now), "Last seen 3 h ago")
        XCTAssertEqual(lastSeenText(now.addingTimeInterval(-30 * 60 * 60), now: now), "Last seen 1 day ago")
        XCTAssertEqual(lastSeenText(now.addingTimeInterval(-2 * 24 * 60 * 60), now: now), "Last seen 2 days ago")
    }

    func testThisDeviceTextRendersLoadingFailureAndMissingValues() {
        XCTAssertEqual(SettingsThisDeviceText(.loading, now: now).name, "Loading…")
        let failed = SettingsThisDeviceText(.failed("offline"), now: now)
        XCTAssertEqual([failed.name, failed.paired, failed.expiry], ["Unavailable", "Unavailable", "Unavailable"])
        let empty = SettingsThisDeviceText(.loaded(SettingsThisDevice()), now: now)
        XCTAssertEqual([empty.name, empty.paired, empty.expiry], ["Unknown", "Unknown", "Unknown"])

        let device = SettingsThisDevice(name: "Sam's iPhone", pairedAt: Date(timeIntervalSince1970: 1_790_726_400), sessionExpiresAt: now.addingTimeInterval(11 * 60 * 60 + 30 * 60))
        let loaded = SettingsThisDeviceText(.loaded(device), now: now, locale: Locale(identifier: "en_AU"), timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual([loaded.name, loaded.paired, loaded.expiry], ["Sam's iPhone", "30 Sep 2026", "in 11 h"])
    }

    func testThisDeviceFromWhoAmIFallsBackToCreatedAtAndDropsBlankNames() {
        let created = Date(timeIntervalSince1970: 100)
        let expires = Date(timeIntervalSince1970: 200)
        let device = SettingsThisDevice(whoAmI: WhoAmI(device: Device(name: "  ", createdAt: created), sessionExpiresAt: expires))
        XCTAssertEqual(device, SettingsThisDevice(name: nil, pairedAt: created, sessionExpiresAt: expires))
    }

    func testPairedDeviceRowsPutThisDeviceFirstThenMostRecentlySeen() {
        let rows = settingsPairedDeviceRows([
            Device(name: "Old iPad", createdAt: Date(timeIntervalSince1970: 1), lastSeenAt: Date(timeIntervalSince1970: 10)),
            Device(name: nil, createdAt: Date(timeIntervalSince1970: 2), lastSeenAt: nil),
            Device(name: "Fixture iPhone", createdAt: Date(timeIntervalSince1970: 3), lastSeenAt: Date(timeIntervalSince1970: 5), thisDevice: true),
            Device(name: "MacBook", createdAt: Date(timeIntervalSince1970: 4), lastSeenAt: Date(timeIntervalSince1970: 20)),
        ])
        XCTAssertEqual(rows.map(\.name), ["Fixture iPhone", "MacBook", "Old iPad", "Unnamed device"])
        XCTAssertEqual(rows.map(\.isThisDevice), [true, false, false, false])
        XCTAssertEqual(Set(rows.map(\.id)).count, 4)
    }

    func testConnectionTextsDescribeEveryState() {
        let at = Date(timeIntervalSince1970: 1)
        XCTAssertEqual(settingsLatencyText(.checking), "Checking…")
        XCTAssertEqual(settingsLatencyText(.reachable(.milliseconds(18))), "18 ms")
        XCTAssertEqual(settingsLatencyText(.unreachable), "Unreachable")
        XCTAssertEqual(connectionTestTitle(.testing), "Testing…")
        XCTAssertEqual(connectionTestTitle(.reachable(latency: .milliseconds(4), at: at)), "Reachable · 4 ms")
        XCTAssertEqual(connectionTestTitle(.unreachable(at: at)), "Can't reach the Mac")
        XCTAssertEqual(
            settingsUnreachableGuidance(address: "127.0.0.1:47832"),
            "cc-controller can't reach 127.0.0.1:47832. Check that Termius is forwarding 127.0.0.1:47832 and the Mac is awake."
        )
    }
}

@MainActor
final class SettingsStoreTests: XCTestCase {
    func testProbingRepeatsWhileVisibleAndStopsWhenHiddenLockedOrInactive() async throws {
        let probes = ProbeCounter()
        let store = makeStore(probe: { probes.count += 1; return DaemonProbe(isReachable: true, latency: .milliseconds(12)) })

        let stops: [(visible: Bool, unlocked: Bool, active: Bool)] = [(false, true, true), (true, false, true), (true, true, false)]
        for stop in stops {
            store.updateProbing(isVisible: true, isUnlocked: true, isActive: true)
            XCTAssertTrue(store.isProbing)
            let started = probes.count
            try await waitUntil { probes.count >= started + 3 }
            XCTAssertEqual(store.latency, .reachable(.milliseconds(12)))

            store.updateProbing(isVisible: stop.visible, isUnlocked: stop.unlocked, isActive: stop.active)
            XCTAssertFalse(store.isProbing)
            let stopped = probes.count
            try await Task.sleep(for: .milliseconds(60))
            XCTAssertEqual(probes.count, stopped, "Probing continued after \(stop)")
        }
    }

    func testFailedProbeMarksUnreachableAndRecoversOnTheNextSample() async throws {
        let probes = ProbeCounter()
        let store = makeStore(probe: {
            probes.count += 1
            if probes.count == 1 { throw AuthError.network("Could not connect to the server.") }
            return DaemonProbe(isReachable: true, latency: .milliseconds(9))
        })
        store.updateProbing(isVisible: true, isUnlocked: true, isActive: true)
        try await waitUntil { store.latency == .reachable(.milliseconds(9)) }
        XCTAssertGreaterThanOrEqual(probes.count, 2)
        store.reset()
        XCTAssertEqual(store.latency, .checking)
        XCTAssertFalse(store.isProbing)
    }

    func testCancelledProbeDoesNotReportTheMacUnreachable() async throws {
        let probes = ProbeCounter()
        let store = makeStore(probe: {
            probes.count += 1
            try await Task.sleep(for: .seconds(30))
            return DaemonProbe(isReachable: true, latency: .milliseconds(1))
        })
        store.updateProbing(isVisible: true, isUnlocked: true, isActive: true)
        try await waitUntil { probes.count == 1 }
        store.updateProbing(isVisible: false, isUnlocked: true, isActive: true)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(store.latency, .checking)
        XCTAssertEqual(probes.count, 1)
    }

    func testTestConnectionProbesImmediatelyAndRecordsBothOutcomes() async {
        var reachable = true
        let probes = ProbeCounter()
        let store = makeStore(probe: {
            probes.count += 1
            guard reachable else { throw AuthError.network("Could not connect to the server.") }
            return DaemonProbe(isReachable: true, latency: .milliseconds(4))
        })

        await store.testConnection()
        XCTAssertEqual(probes.count, 1)
        XCTAssertEqual(store.connectionTest, .reachable(latency: .milliseconds(4), at: TestSettingsClock.fixedNow))
        XCTAssertEqual(store.latency, .reachable(.milliseconds(4)))
        XCTAssertFalse(store.isProbing)

        reachable = false
        await store.testConnection()
        XCTAssertEqual(probes.count, 2)
        XCTAssertEqual(store.connectionTest, .unreachable(at: TestSettingsClock.fixedNow))
        XCTAssertEqual(store.latency, .unreachable)
    }

    func testLoadFillsThisDeviceAndPairedDevices() async {
        let paired = Date(timeIntervalSince1970: 1_000)
        let expires = Date(timeIntervalSince1970: 2_000)
        let store = makeStore(
            whoAmI: { WhoAmI(device: Device(name: "Fixture iPhone", pairedAt: paired), sessionExpiresAt: expires) },
            devices: {
                [
                    Device(name: "Fixture iPad", createdAt: Date(timeIntervalSince1970: 1), lastSeenAt: Date(timeIntervalSince1970: 1)),
                    Device(name: "Fixture iPhone", createdAt: Date(timeIntervalSince1970: 2), lastSeenAt: Date(timeIntervalSince1970: 2), thisDevice: true),
                ]
            }
        )
        XCTAssertEqual(store.thisDevice, .loading)
        XCTAssertEqual(store.pairedDevices, .loading)

        await store.load()
        XCTAssertEqual(store.thisDevice, .loaded(SettingsThisDevice(name: "Fixture iPhone", pairedAt: paired, sessionExpiresAt: expires)))
        guard case .loaded(let rows) = store.pairedDevices else { return XCTFail("Devices did not load") }
        XCTAssertEqual(rows.map(\.name), ["Fixture iPhone", "Fixture iPad"])
        XCTAssertEqual(rows.first?.isThisDevice, true)
    }

    func testLoadReportsFailuresAndEmptyDeviceLists() async {
        let failing = makeStore(
            whoAmI: { throw APIError.transport(URLError(.cannotConnectToHost)) },
            devices: { throw APIError.http(status: 500, message: "boom", code: nil) }
        )
        await failing.load()
        guard case .failed = failing.thisDevice else { return XCTFail("This device did not fail") }
        XCTAssertEqual(failing.pairedDevices, .failed("HTTP 500: boom"))

        let empty = makeStore(devices: { [] })
        await empty.loadPairedDevices()
        XCTAssertEqual(empty.pairedDevices, .loaded([]))
    }

    private func makeStore(
        probe: @escaping @MainActor () async throws -> DaemonProbe = { DaemonProbe(isReachable: true, latency: .milliseconds(1)) },
        whoAmI: @escaping @MainActor () async throws -> WhoAmI = { WhoAmI() },
        devices: @escaping @MainActor () async throws -> [Device] = { [] }
    ) -> SettingsStore {
        SettingsStore(probe: probe, whoAmI: whoAmI, devices: devices, clock: TestSettingsClock(), interval: .milliseconds(5))
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Condition was not met in time") }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

@MainActor
private final class ProbeCounter {
    var count = 0
}

private struct TestSettingsClock: CCKitClock {
    static let fixedNow = Date(timeIntervalSince1970: 1_790_000_000)
    var now: Date { Self.fixedNow }

    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
