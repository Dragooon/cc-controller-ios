import Foundation
import XCTest
@testable import CCKit

@MainActor
final class LiveFixtureTests: XCTestCase {
    func testLiveFixtureAppStoreReadsSessionsAndLiveEvents() async throws {
        let (url, bearer) = try fixtureCredentials()
        let app = AppStore(
            serverURL: url,
            bearerProvider: { bearer },
            cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        app.start()
        defer { app.suspend() }
        try await waitUntil { if case .live = app.connection { return true }; return false }
        XCTAssertGreaterThanOrEqual(app.sessions.count, 5)
        XCTAssertGreaterThanOrEqual(app.approvals.count, 2)
        let firstApproval = try XCTUnwrap(app.approvals.first(where: { $0.sessionId == "approval-flow-light-mode" }))
        let secondApproval = try XCTUnwrap(app.approvals.first(where: { $0.sessionId == "staff-account-exclusions" }))
        guard case .success = await app.allow(firstApproval) else { return XCTFail("Fixture allow failed") }
        guard case .success = await app.deny(secondApproval) else { return XCTFail("Fixture deny failed") }
        XCTAssertTrue(app.approvals.isEmpty)

        guard case .failure(.noPane) = await app.send(text: "send now", to: "approval-flow-light-mode", now: true) else { return XCTFail("Expected fixture no-pane send-now error") }
        let upload = await app.upload([UploadFile(name: "native.png", data: Data([137, 80, 78, 71]), mimeType: "image/png")], to: "staff-account-exclusions")
        guard case .success(let files) = upload, files.first?.name == "native.png" else { return XCTFail("Fixture upload failed: \(upload)") }
        guard case .success = await app.setApprovalMode(sessionID: "staff-account-exclusions", mode: .remote) else { return XCTFail("Fixture mode update failed") }
        app.suspend()
        app.resume()
        try await waitUntil { if case .live = app.connection { return true }; return false }
        XCTAssertEqual(app.sessions["staff-account-exclusions"]?.mode, .remote)

        let session = try XCTUnwrap(app.openSession("long-session"))
        try await waitUntil { session.isLoaded }
        let tailCount = session.entries.count
        XCTAssertEqual(tailCount, 400)
        XCTAssertTrue(session.hasMoreEarlier)
        try await session.loadEarlier()
        XCTAssertEqual(session.entries.count, 800)
        XCTAssertTrue(session.hasMoreEarlier)
        try await session.loadEarlier()
        XCTAssertEqual(session.entries.count, 1000)
        XCTAssertFalse(session.hasMoreEarlier)

        try await waitUntil {
            app.sessions["dune-part-three-imax-tickets"]?.state == .working
        }
    }

    private func fixtureCredentials() throws -> (URL, String) {
        let environment = ProcessInfo.processInfo.environment
        guard let urlString = environment["CC_FIXTURE_URL"], let url = URL(string: urlString), let bearer = environment["CC_FIXTURE_BEARER"], !bearer.isEmpty else {
            throw XCTSkip("CC_FIXTURE_URL and CC_FIXTURE_BEARER are not set")
        }
        return (url, bearer)
    }

    private func waitUntil(_ predicate: @escaping () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTFail("Timed out waiting for fixture state")
    }
}
