import XCTest

/// Captures README screenshots. Runs only when `SCREENSHOT_DIR` is set (pass it to xcodebuild as
/// `TEST_RUNNER_SCREENSHOT_DIR=/path`); needs network access to clone a public repository.
final class ScreenshotUITests: XCTestCase {
    func testCaptureReadmeScreenshots() throws {
        guard let directory = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] else {
            throw XCTSkip("Set TEST_RUNNER_SCREENSHOT_DIR to capture screenshots")
        }
        let app = XCUIApplication()
        // Portrait: XCUIScreen screenshots are in device orientation, so landscape shots would
        // come out sideways.
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let showSidebar = app.buttons["Show Sidebar"].firstMatch
        if showSidebar.waitForExistence(timeout: 3) { showSidebar.tap() }

        let repoName = "GitPad"
        // Look only inside the sidebar list: the navigation bar title is also "GitPad".
        let repoRow = app.collectionViews["Sidebar"].staticTexts[repoName].firstMatch
        if !repoRow.waitForExistence(timeout: 3) {
            app.buttons["Clone"].firstMatch.tap()
            let url = app.textFields.firstMatch
            XCTAssertTrue(url.waitForExistence(timeout: 5))
            url.tap()
            url.typeText("https://github.com/BerkGozek/GitPad.git")
            // Regression: typing the URL froze the folder name at its first character ("h").
            XCTAssertEqual(app.textFields["clone-name"].value as? String, repoName)
            save(app, "clone", to: directory)
            app.navigationBars["Clone Repository"].buttons["Clone"].tap()
            if !repoRow.waitForExistence(timeout: 60) {
                save(app, "clone-failed", to: directory)
                print("UI-DUMP-BEGIN\n\(app.debugDescription)\nUI-DUMP-END")
                XCTFail("Clone didn't finish")
                return
            }
        }
        repoRow.tap()
        sleep(2)
        save(app, "files", to: directory)

        app.buttons["History"].firstMatch.tap()
        sleep(1)
        save(app, "history", to: directory)

        app.buttons["Branches"].firstMatch.tap()
        sleep(1)
        save(app, "branches", to: directory)
    }

    private func save(_ app: XCUIApplication, _ name: String, to directory: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try? data.write(to: url)
    }
}
