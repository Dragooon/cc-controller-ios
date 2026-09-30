import Foundation
import XCTest
@testable import CCKit

final class FixtureTests: XCTestCase {
    func testEveryMappedContractFixtureDecodes() throws {
        let manifestURL = try XCTUnwrap(Bundle.module.url(forResource: "manifest", withExtension: "json"))
        let manifest = try JSONDecoder().decode([String: FixtureSpec].self, from: Data(contentsOf: manifestURL))
        var failures: [String] = []
        for (filename, spec) in manifest.sorted(by: { $0.key < $1.key }) {
            if spec.skip { continue }
            guard let url = Bundle.module.url(forResource: filename.replacingOccurrences(of: ".json", with: ""), withExtension: "json") else { failures.append("\(filename): missing resource"); continue }
            do { try decodeFixture(Data(contentsOf: url), as: spec.type) } catch { failures.append("\(filename): \(error)") }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    private func decodeFixture(_ data: Data, as type: String) throws {
        let decoder = JSONDecoder.ccKit()
        switch type {
        case "Bootstrap": _ = try decoder.decode(Bootstrap.self, from: data)
        case "StateSnapshot": _ = try decoder.decode(StateSnapshot.self, from: data)
        case "StateDelta": _ = try decoder.decode(StateDelta.self, from: data)
        case "TranscriptEntry": _ = try decoder.decode(TranscriptEntry.self, from: data)
        case "TranscriptArray": _ = try decoder.decode([TranscriptEntry].self, from: data)
        case "UsageEvent": _ = try decoder.decode(UsageEvent.self, from: data)
        case "SubagentsEvent": _ = try decoder.decode(SubagentsEvent.self, from: data)
        case "ApprovalEvent": _ = try decoder.decode(ApprovalEvent.self, from: data)
        case "DecisionEvent": _ = try decoder.decode(DecisionEvent.self, from: data)
        case "TranscriptEvent": _ = try decoder.decode(TranscriptEvent.self, from: data)
        case "FileEvent": _ = try decoder.decode(FileEvent.self, from: data)
        case "RegistryEvent": _ = try decoder.decode(RegistryEvent.self, from: data)
        case "WhoAmI": _ = try decoder.decode(WhoAmI.self, from: data)
        case "DeviceList": _ = try decoder.decode(DeviceList.self, from: data)
        case "PairStartResponse": _ = try decoder.decode(PairStartResponse.self, from: data)
        case "PairPollResponse": _ = try decoder.decode(PairPollResponse.self, from: data)
        case "NativeEnrollResponse": _ = try decoder.decode(NativeEnrollResponse.self, from: data)
        case "NativeLoginResponse": _ = try decoder.decode(NativeLoginResponse.self, from: data)
        case "MessageResult": _ = try decoder.decode(MessageResult.self, from: data)
        case "KeyResult": _ = try decoder.decode(KeyResult.self, from: data)
        case "ModeResult": _ = try decoder.decode(ModeResult.self, from: data)
        case "Decision": _ = try decoder.decode(Decision.self, from: data)
        case "UploadResponse": _ = try decoder.decode(UploadResponse.self, from: data)
        case "UploadedFile": _ = try decoder.decode(UploadedFile.self, from: data)
        case "JSONValue": _ = try decoder.decode(JSONValue.self, from: data)
        default: XCTFail("Unknown fixture type \(type)")
        }
    }
}

private struct FixtureSpec: Decodable {
    let type: String
    let skip: Bool
    let reason: String?
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        skip = try container.decodeIfPresent(Bool.self, forKey: .skip) ?? false
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
    }
    private enum CodingKeys: String, CodingKey { case type, skip, reason }
}
