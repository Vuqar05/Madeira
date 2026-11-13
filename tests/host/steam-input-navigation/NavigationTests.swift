// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import XCTest
final class NavigationTests: XCTestCase {
    func testSessionCommunityNavigation() { checkNavigation(details: false) }
    func testDetailsCommunityNavigation() { checkNavigation(details: true) }
    private func checkNavigation(details: Bool) {
        let app = XCUIApplication()
        if details { app.launchArguments = ["details"] }
        app.launch()
        let community = app.buttons["Community layouts"].firstMatch
        XCTAssertTrue(community.waitForExistence(timeout: 5))
        XCTAssertTrue(community.isEnabled, "Community layouts must be actionable in this presentation context")
        community.tap()
        let layout = app.buttons["Fixture layout"]
        XCTAssertTrue(layout.waitForExistence(timeout: 3), "Community layouts did not open")
        guard layout.exists else { return }
        // The status refreshes every second; presentation must outlive ticks.
        Thread.sleep(forTimeInterval: 2.2)
        XCTAssertTrue(layout.exists)
        layout.tap()
        XCTAssertTrue(app.staticTexts["revision"].waitForExistence(timeout: 3))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(layout.waitForExistence(timeout: 3))
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 3), "The community browser must remain dismissible")
        guard done.exists else { return }
        done.tap()
        XCTAssertFalse(app.staticTexts["revision"].exists)
        community.tap()
        XCTAssertTrue(layout.waitForExistence(timeout: 3), "Community layouts must reopen after dismissal")
    }
}
