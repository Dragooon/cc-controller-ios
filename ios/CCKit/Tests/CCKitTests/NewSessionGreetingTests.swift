import Foundation
import XCTest
@testable import CCKit

final class NewSessionGreetingTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testTimeBuckets() {
        XCTAssertEqual(greeting("2026-10-28T05:00:00Z", name: "Alex"), "Good morning, Alex")
        XCTAssertEqual(greeting("2026-10-28T12:00:00Z", name: "Alex"), "Good afternoon, Alex")
        XCTAssertEqual(greeting("2026-10-28T17:00:00Z", name: "Alex"), "Good evening, Alex")
        XCTAssertEqual(greeting("2026-10-28T22:00:00Z", name: "Alex"), "Hello, night owl")
    }

    func testWeekdayVariant() {
        let date = date("2026-10-28T06:00:00Z")
        XCTAssertEqual(NewSessionGreeting.text(date: date, name: "Alex", calendar: calendar), "Happy Wednesday, Alex")
    }

    func testDropsNameWhenUnavailable() {
        XCTAssertEqual(greeting("2026-10-28T06:00:00Z", name: nil), "Happy Wednesday")
        XCTAssertEqual(greeting("2026-10-28T13:00:00Z", name: "   "), "Good afternoon")
    }

    func testIsDeterministic() {
        let date = date("2026-10-28T13:15:00Z")
        let values = (0..<20).map { _ in NewSessionGreeting.text(date: date, name: "Alex", calendar: calendar) }
        XCTAssertEqual(Set(values), [values[0]])
    }

    private func greeting(_ value: String, name: String?) -> String {
        NewSessionGreeting.text(date: date(value), name: name, calendar: calendar)
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
