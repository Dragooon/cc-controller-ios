import Foundation
import XCTest
@testable import CCKit

final class LiveFixtureTests: XCTestCase {
    func testOptionalFixtureDaemon() async throws {
        guard let urlString = ProcessInfo.processInfo.environment["CC_FIXTURE_URL"], let url = URL(string: urlString), let bearer = ProcessInfo.processInfo.environment["CC_FIXTURE_BEARER"], !bearer.isEmpty else { throw XCTSkip("CC_FIXTURE_URL and CC_FIXTURE_BEARER are not set") }
        let client = APIClient(baseURL: url, bearerToken: bearer)
        _ = try await client.bootstrap()
        _ = try await client.transcript(sessionID: "default")
        let stream = EventStream(client: client)
        await stream.start()
        try await Task.sleep(for: .seconds(3))
        await stream.stop()
    }
}
