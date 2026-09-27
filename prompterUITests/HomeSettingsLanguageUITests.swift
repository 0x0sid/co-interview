import XCTest

/// The interview language lives in Settings only: the home screen has no language selector, and
/// Settings shows Interview Language with its current value and the speech model's state.
@MainActor
final class HomeSettingsLanguageUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testInterviewLanguageIsInSettingsNotOnHome() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestsQuietMotion"]
        app.launch()
        XCTAssertTrue(app.waitForNeverblankHome(), "home did not appear")

        let anyLanguageRow = app.descendants(matching: .any).matching(identifier: "interview-language").firstMatch
        XCTAssertFalse(anyLanguageRow.exists, "the home screen still has an interview-language selector")
        XCTAssertFalse(app.staticTexts["Interview language"].exists)

        app.buttons["home-settings"].tap()
        let row = app.buttons["interview-language"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Settings has no Interview Language row")
        XCTAssertTrue(row.label.contains("Interview Language"), "row label: \(row.label)")
        let state = app.descendants(matching: .any).matching(NSPredicate(format:
            "identifier IN {'speech-model-ready','speech-model-download','speech-model-unsupported','speech-model-retry','speech-model-progress'}")).firstMatch
        let checking = app.staticTexts["Checking the speech model…"]
        XCTAssertTrue(state.waitForExistence(timeout: 10) || checking.exists, "Settings shows no speech-model state")
    }
}
