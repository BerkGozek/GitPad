import XCTest

/// Drives the real app in the simulator.
final class AccountFlowUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    private func openSettings() {
        // The sidebar (with the Settings button) is always visible in landscape.
        XCUIDevice.shared.orientation = .landscapeLeft
        // With a repository already open, the sidebar can start collapsed.
        let showSidebar = app.buttons["Show Sidebar"].firstMatch
        if showSidebar.waitForExistence(timeout: 3) { showSidebar.tap() }
        let settings = app.buttons["Settings"].firstMatch
        if !settings.waitForExistence(timeout: 10) {
            print("UI-DUMP-BEGIN\n\(app.debugDescription)\nUI-DUMP-END")
            XCTFail("Settings button not found")
        }
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5), "Settings didn't open")
    }

    /// Regression test: tapping "Add Account…" closed the screen instead of showing the form.
    func testAddAccountFormStaysOpenWhileTyping() {
        openSettings()
        let add = app.buttons["Add Account…"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()

        let addBar = app.navigationBars["Add Account"]
        XCTAssertTrue(addBar.waitForExistence(timeout: 5), "Add Account form didn't appear")

        let token = app.secureTextFields["Personal access token"]
        if !token.waitForExistence(timeout: 5) {
            print("UI-DUMP-BEGIN\n\(app.debugDescription)\nUI-DUMP-END")
            XCTFail("Token field not found (form closed?)")
        }
        token.tap()
        token.typeText("not-a-real-token")
        XCTAssertTrue(addBar.exists, "Add Account form closed while typing")

        // Switching provider must not close it either.
        app.buttons["service-picker"].firstMatch.tap()
        let gitlab = app.buttons["GitLab"].firstMatch
        if gitlab.waitForExistence(timeout: 3) { gitlab.tap() }
        XCTAssertTrue(addBar.waitForExistence(timeout: 3), "Add Account form closed after changing service")

        addBar.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5), "Cancel should return to Settings")
    }
}
