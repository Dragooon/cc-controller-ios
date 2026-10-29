import Foundation
import XCTest

@MainActor
func pollUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    if condition() { return true }

    let deadline = Date().addingTimeInterval(timeout)
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

    func waitToDisappear(timeout: TimeInterval) -> Bool {
        var result = false
        XCTContext.runActivity(named: "Waiting \(timeout)s for \(description) to not exist") { _ in
            result = pollUntil(timeout: timeout) { !exists }
        }
        return result
    }
}
