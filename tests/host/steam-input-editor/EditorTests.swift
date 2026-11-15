// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import XCTest

/// Drives the production personal-layout list, page and editor on a simulator.
final class EditorTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ arguments: [String] = ["reset"]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }

    /// Scrolls until the element is on screen.
    @discardableResult private func reveal(_ element: XCUIElement, in app: XCUIApplication, file: StaticString = #file, line: UInt = #line) -> XCUIElement {
        for _ in 0..<12 where !(element.exists && element.isHittable) { app.swipeUp() }
        if !element.exists { for _ in 0..<12 where !(element.exists && element.isHittable) { app.swipeDown() } }
        XCTAssertTrue(element.waitForExistence(timeout: 3), "\(element) not found", file: file, line: line)
        return element
    }

    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func openSeedEditor(_ app: XCUIApplication) {
        element("personal.Seed", app).tap()
        reveal(element("detail.edit", app), in: app).tap()
        XCTAssertTrue(app.navigationBars["Edit layout"].waitForExistence(timeout: 5))
    }

    private func openFaceButtons(_ app: XCUIApplication) {
        reveal(element("source.button_diamond.edit", app), in: app).tap()
        XCTAssertTrue(app.navigationBars["Face buttons"].waitForExistence(timeout: 5))
        reveal(element("binding.button_a.Full_Press.0", app), in: app)
    }

    private func bindingText(_ app: XCUIApplication) -> String {
        element("binding.button_a.Full_Press.0", app).label
    }

    private func chooseGamepad(_ title: String, _ app: XCUIApplication) {
        reveal(element("binding.button_a.Full_Press.0.edit", app), in: app).tap()
        let picker = element("bindingEditor.gamepad", app)
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        app.buttons[title].firstMatch.tap()
        element("bindingEditor.done", app).tap()
        XCTAssertTrue(element("binding.button_a.Full_Press.0", app).waitForExistence(timeout: 5))
    }

    func testEditUndoRedoSaveAndHistory() {
        let app = launch()
        openSeedEditor(app)
        // Content the editor cannot edit is shown and kept.
        reveal(element("unsupported.future_block", app), in: app)
        openFaceButtons(app)
        XCTAssertTrue(bindingText(app).hasPrefix("A (Cross)"), bindingText(app))
        chooseGamepad("B (Circle)", app)
        XCTAssertTrue(bindingText(app).hasPrefix("B (Circle)"), bindingText(app))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        element("editor.undo", app).tap()
        openFaceButtons(app)
        XCTAssertTrue(bindingText(app).hasPrefix("A (Cross)"), "undo restores the binding: \(bindingText(app))")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        element("editor.redo", app).tap()
        openFaceButtons(app)
        XCTAssertTrue(bindingText(app).hasPrefix("B (Circle)"), "redo reapplies it")
        // Toggle and turbo on the same activator.
        reveal(element("activator.button_a.Full_Press.toggle", app), in: app).switches.firstMatch.tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        element("editor.save", app).tap()
        XCTAssertTrue(reveal(element("editor.message", app), in: app).label.hasPrefix("Saved as a new revision."))
        XCTAssertFalse(element("editor.save", app).isEnabled, "nothing left to save")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(reveal(element("detail.history", app), in: app).label.contains("(2)"), element("detail.history", app).label)
        element("detail.history", app).tap()
        element("history.restore.0", app).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(reveal(element("detail.history", app), in: app).label.contains("(3)"), "restore adds a revision")
        reveal(element("detail.edit", app), in: app).tap()
        openFaceButtons(app)
        XCTAssertTrue(bindingText(app).hasPrefix("A (Cross)"), "the restored revision is current")
    }

    /// Item 6 through the UI: a field the editor cannot edit is listed, survives
    /// an edit, a save and a relaunch byte for byte, and the saved revision is
    /// what the editor reads back.
    func testUnsupportedFieldsSurviveEditSaveAndRelaunch() {
        var app = launch()
        openSeedEditor(app)
        let raw = "\"future_block\" { \"kept\" \"exactly\" }"
        XCTAssertTrue(reveal(element("unsupported.future_block", app), in: app).label.contains(raw), element("unsupported.future_block", app).label)
        openFaceButtons(app)
        chooseGamepad("X (Square)", app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        element("editor.save", app).tap()
        XCTAssertTrue(reveal(element("editor.message", app), in: app).label.hasPrefix("Saved as a new revision."))
        app.terminate()
        app = launch([])
        openSeedEditor(app)
        XCTAssertFalse(element("editor.resumeDraft", app).exists, "the edit was saved, not left as a draft")
        XCTAssertTrue(reveal(element("unsupported.future_block", app), in: app).label.contains(raw), "the saved revision keeps the field exactly")
        openFaceButtons(app)
        XCTAssertTrue(bindingText(app).hasPrefix("X (Square)"), "the saved revision holds the edit")
    }

    func testUnsavedEditsSurviveRelaunch() {
        var app = launch()
        openSeedEditor(app)
        openFaceButtons(app)
        chooseGamepad("Y (Triangle)", app)
        app.terminate()
        app = launch([])
        openSeedEditor(app)
        let resume = reveal(element("editor.resumeDraft", app), in: app)
        resume.tap()
        openFaceButtons(app)
        XCTAssertTrue(bindingText(app).hasPrefix("Y (Triangle)"), "the draft is restored after a relaunch")
    }

    func testCreateRenameDuplicateAndDelete() {
        let app = launch()
        element("personal.new", app).tap()
        let name = element("create.name", app)
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20) + "From template")
        element("create.template.Gamepad", app).tap()
        XCTAssertTrue(element("personal.From template", app).waitForExistence(timeout: 5), "a template creates a layout")
        element("personal.new", app).tap()
        element("create.default", app).tap()
        XCTAssertTrue(element("personal.My layout", app).waitForExistence(timeout: 5), "the game default creates a layout")
        element("personal.From template", app).tap()
        element("detail.duplicate", app).tap()
        XCTAssertTrue(reveal(element("detail.message", app), in: app).label.hasPrefix("Made “From template copy”"))
        let field = reveal(element("detail.name", app), in: app)
        field.tap()
        for _ in 0..<20 { field.typeText(XCUIKeyboardKey.delete.rawValue) }
        field.typeText("Renamed")
        element("detail.rename", app).tap()
        XCTAssertTrue(element("detail.title", app).label == "Renamed")
        reveal(element("detail.delete", app), in: app).tap()
        app.buttons["Delete layout and its history"].tap()
        XCTAssertTrue(element("personal.From template copy", app).waitForExistence(timeout: 5))
        XCTAssertFalse(element("personal.Renamed", app).exists, "the deleted layout is gone")
    }

    func testChosenLayoutCannotBeDeleted() {
        let app = launch(["reset", "selected"])
        element("personal.Seed", app).tap()
        reveal(element("detail.delete", app), in: app).tap()
        app.buttons["Delete layout and its history"].tap()
        XCTAssertTrue(reveal(element("detail.failure", app), in: app).label.hasPrefix("This layout is this game's chosen Steam Input layout."))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(element("personal.Seed", app).waitForExistence(timeout: 5))
    }

    func testDamagedLayoutIsRecovered() {
        let app = launch(["reset", "damaged"])
        let damaged = element("personal.damaged.Damaged layout", app)
        XCTAssertTrue(damaged.waitForExistence(timeout: 5), "a damaged layout is listed, not hidden")
        XCTAssertTrue(element("personal.Seed", app).exists, "the other layouts still list")
        damaged.tap()
        element("recovery.recover", app).tap()
        XCTAssertTrue(element("recovery.done", app).waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(element("personal.Recovered layout", app).waitForExistence(timeout: 5))
    }

    func testModesAndActionSets() {
        let app = launch()
        openSeedEditor(app)
        let source = reveal(element("source.button_diamond", app), in: app)
        source.tap()
        app.buttons["Directional Pad"].firstMatch.tap()
        XCTAssertTrue(reveal(element("source.button_diamond", app), in: app).label.contains("Directional Pad"), element("source.button_diamond", app).label)
        reveal(element("source.button_diamond", app), in: app).tap()
        app.buttons["Buttons"].firstMatch.tap()
        openFaceButtons(app)
        XCTAssertTrue(bindingText(app).hasPrefix("A (Cross)"), "switching back restores the earlier group's bindings")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        reveal(app.textFields["New action set"], in: app)
        // Keep the field clear of the keyboard its tap brings up: with a longer
        // compatibility note above it, it can otherwise sit under the keyboard.
        app.swipeUp()
        let newSet = reveal(app.textFields["New action set"], in: app)
        newSet.tap(); newSet.typeText("Driving")
        newSet.coordinate(withNormalizedOffset: CGVector(dx: 1.05, dy: 0.5)).tap()
        let add = app.buttons["Add"].firstMatch
        if add.exists && add.isEnabled { add.tap() }
        reveal(element("editor.preset", app), in: app).tap()
        XCTAssertTrue(app.buttons["Driving"].firstMatch.waitForExistence(timeout: 5), "the new action set can be chosen")
    }
}
