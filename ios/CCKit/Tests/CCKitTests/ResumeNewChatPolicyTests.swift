import Foundation
import XCTest
@testable import CCKit

final class ResumeNewChatPolicyTests: XCTestCase {
    private let backgroundAt = Date(timeIntervalSince1970: 1_000)

    func testStaysBeforeThreshold() {
        XCTAssertFalse(ResumeNewChatPolicy.shouldResume(
            backgroundAt: backgroundAt,
            now: backgroundAt.addingTimeInterval(599),
            hasPendingApprovals: false,
            isOnNewChat: false,
            isPaired: true
        ))
    }

    func testResumesAtThreshold() {
        XCTAssertTrue(ResumeNewChatPolicy.shouldResume(
            backgroundAt: backgroundAt,
            now: backgroundAt.addingTimeInterval(600),
            hasPendingApprovals: false,
            isOnNewChat: false,
            isPaired: true
        ))
    }

    func testPendingApprovalStaysOnCurrentScreen() {
        XCTAssertFalse(ResumeNewChatPolicy.shouldResume(
            backgroundAt: backgroundAt,
            now: backgroundAt.addingTimeInterval(600),
            hasPendingApprovals: true,
            isOnNewChat: false,
            isPaired: true
        ))
    }

    func testAlreadyOnNewChatStaysOnNewChat() {
        XCTAssertFalse(ResumeNewChatPolicy.shouldResume(
            backgroundAt: backgroundAt,
            now: backgroundAt.addingTimeInterval(600),
            hasPendingApprovals: false,
            isOnNewChat: true,
            isPaired: true
        ))
    }

    func testUnpairedAppStaysOnCurrentScreen() {
        XCTAssertFalse(ResumeNewChatPolicy.shouldResume(
            backgroundAt: backgroundAt,
            now: backgroundAt.addingTimeInterval(600),
            hasPendingApprovals: false,
            isOnNewChat: false,
            isPaired: false
        ))
    }
}
