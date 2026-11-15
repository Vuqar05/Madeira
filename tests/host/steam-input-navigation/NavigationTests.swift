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
        let community = app.buttons["steamInput.layouts"].firstMatch
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

    /// Milestone 5 item 4: Game details shows the saved choice while the game
    /// is not running, and can return it to the game default.
    func testDetailsSavedChoice() {
        let app = XCUIApplication()
        app.launchArguments = ["details", "saved"]
        app.launch()
        let state = app.staticTexts["steamInput.state"]
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        XCTAssertTrue(state.label.hasPrefix("Chosen: Personal layout"), state.label)
        XCTAssertTrue(app.staticTexts["steamInput.controller"].label.contains("Steam sees"))
        app.buttons["steamInput.clearOverride"].tap()
        XCTAssertTrue(app.staticTexts["Chosen: Game default (Steam's saved layout for this game)."].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["steamInput.clearOverride"].exists)
    }

    /// Milestone 5 item 2 in the session menu: a held layout lists what is
    /// missing and loads only after "Apply anyway".
    func testSessionHeldLayoutConfirmation() {
        let app = XCUIApplication()
        app.launchArguments = ["held"]
        app.launch()
        let state = app.staticTexts["steamInput.state"]
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        XCTAssertTrue(state.label.hasPrefix("Needs your confirmation"), state.label)
        XCTAssertTrue(app.staticTexts["steamInput.held"].label.contains("controls made for a Steam Deck, rear buttons"))
        app.buttons["steamInput.held.confirm"].tap()
        let alert = app.alerts["Made for another controller"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        XCTAssertTrue(alert.staticTexts.allElementsBoundByIndex.contains { $0.label.contains("maps what it can") })
        alert.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["steamInput.held"].exists, "cancel keeps the layout held")
        app.buttons["steamInput.held.confirm"].tap()
        app.alerts["Made for another controller"].buttons["Apply anyway"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Loading the layout into Steam Input…"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["steamInput.held"].exists)
    }
}
