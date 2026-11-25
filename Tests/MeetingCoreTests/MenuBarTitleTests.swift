import Foundation
import MeetingCore
import XCTest

final class MenuBarTitleTests: XCTestCase {
    func testCountdown() {
        let now = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertEqual(MenuBarTitle.countdown(to: now, from: now), "now")
        XCTAssertEqual(MenuBarTitle.countdown(to: now.addingTimeInterval(9.2), from: now), "in 10s")
        XCTAssertEqual(MenuBarTitle.countdown(to: now.addingTimeInterval(59), from: now), "in 59s")
        XCTAssertEqual(MenuBarTitle.countdown(to: now.addingTimeInterval(60), from: now), "in 1m")
        XCTAssertEqual(MenuBarTitle.countdown(to: now.addingTimeInterval(-120), from: now), "now")
        XCTAssertEqual(MenuBarTitle.countdown(to: now.addingTimeInterval(250), from: now), "in 5m")
        XCTAssertEqual(MenuBarTitle.countdown(to: now.addingTimeInterval(3600), from: now), "in 1h")
        XCTAssertEqual(MenuBarTitle.countdown(to: now.addingTimeInterval(3600 + 20 * 60), from: now), "in 1h 20m")
        XCTAssertEqual(MenuBarTitle.countdown(to: now.addingTimeInterval(59 * 60 + 30), from: now), "in 1h")
    }

    func testHeuristicStripsBoilerplate() {
        XCTAssertEqual(MenuBarTitle.heuristic("Invitation: Weekly Sync @ Tue Oct 7, 2026 10am"), "Weekly Sync")
        XCTAssertEqual(MenuBarTitle.heuristic("[EXTERNAL] Acme review (Recurring)"), "Acme review")
        XCTAssertEqual(MenuBarTitle.heuristic("Roadmap check-in - 10/14"), "Roadmap check-in")
        XCTAssertEqual(MenuBarTitle.heuristic("FW: RE: Budget"), "Budget")
    }

    func testHeuristicFits() {
        let long = "Quarterly Business Review with the Platform Infrastructure Team and Stakeholders"
        let short = MenuBarTitle.heuristic(long)
        XCTAssertLessThanOrEqual(short.count, MenuBarTitle.maxLength)
        XCTAssert(short.hasSuffix("…"))
        XCTAssert(short.hasPrefix("Quarterly Business"))
    }

    func testTruncateLeavesShortTitles() {
        XCTAssertEqual(MenuBarTitle.truncate("Standup"), "Standup")
        XCTAssertEqual(MenuBarTitle.truncate("Supercalifragilisticexpialidocious").count, MenuBarTitle.maxLength)
    }
}
