import Foundation
import XCTest

@MainActor
func pollUntil(timeout: TimeInterval, scaled: Bool = true, _ condition: () -> Bool) -> Bool {
    if condition() { return true }

    // A budget is a limit, not a delay: a passing wait still returns as soon as its condition holds.
    let deadline = Date().addingTimeInterval(scaled ? timeout * flowTimeScale() : timeout)
    while Date() < deadline {
        RunLoop.current.run(until: min(Date().addingTimeInterval(0.2), deadline))
        if condition() { return true }
    }
    return condition()
}

@MainActor
extension XCUIElement {
    func waitToExist(timeout: TimeInterval) -> Bool {
        var result = false
        XCTContext.runActivity(named: "Waiting \(timeout)s for \(description) to exist") { _ in
            result = pollUntil(timeout: timeout) { exists }
        }
        return result
    }

    /// `isHittable` fails the test outright while an element has no frame yet, as it does mid-transition.
    var isSafelyHittable: Bool {
        guard let snapshot = try? snapshot(), !snapshot.frame.isEmpty else { return false }
        return isHittable
    }

    func waitToDisappear(timeout: TimeInterval) -> Bool {
        var result = false
        XCTContext.runActivity(named: "Waiting \(timeout)s for \(description) to not exist") { _ in
            result = pollUntil(timeout: timeout) { !exists }
        }
        return result
    }
}
