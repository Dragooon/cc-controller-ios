import XCTest
@testable import CCKit

final class PeerPresentationTests: XCTestCase {
    func testPeerSenderSplitsLabelAndHost() {
        let sender = peerSender(from: "Stockade · thread \"Dune relay\" [mustafar:3fa9c1]")
        XCTAssertEqual(sender, PeerSender(label: "Stockade · thread \"Dune relay\"", host: "mustafar"))
        XCTAssertEqual(sender.headerText, "From Stockade · thread \"Dune relay\" · mustafar")
    }

    func testPeerSenderWithoutBracketedSuffixIsAllLabel() {
        let sender = peerSender(from: "  Kepler  ")
        XCTAssertEqual(sender, PeerSender(label: "Kepler", host: nil))
        XCTAssertEqual(sender.headerText, "From Kepler")
        XCTAssertNil(peerSender(from: "Kepler [mustafar:3fa9c1] trailing").host)
        XCTAssertNil(peerSender(from: "[mustafar:3fa9c1]").host)
    }

    func testOnlyPeerOriginHasASender() {
        XCTAssertNil(PromptEntry(origin: "device", from: "cc-controller", text: "hi").peerSender)
        XCTAssertNil(PromptEntry(origin: "terminal", text: "hi").peerSender)
        XCTAssertNil(PromptEntry(text: "hi").peerSender)
        XCTAssertEqual(
            PromptEntry(origin: "peer", from: "Madge [mustafar:abc]", text: "hi").peerSender,
            PeerSender(label: "Madge", host: "mustafar")
        )
        XCTAssertEqual(PromptEntry(origin: "peer", text: "hi").peerSender?.headerText, "From another session")
    }
}
