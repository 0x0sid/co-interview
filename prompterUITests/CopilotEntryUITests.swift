import XCTest

/// The owner-facing path, driven by taps only: launch the app normally, find **Interview Copilot** on
/// the home screen, start the demo, and see cards appear with readable answers.
///
/// This exists because the copilot was previously reachable only through a launch argument, so a
/// normal launch showed nothing but the teleprompter. A test that used the launch argument would have
/// kept saying "it works" while the owner saw the old screen — so this one navigates the way a person
/// does, and captures screenshots as evidence.
///
/// Everything it shows is synthetic: a scripted interview, a sample project and the clearly-marked
/// development fake provider.
final class CopilotEntryUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        return app
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Home → Interview Copilot → Start demo, with no launch arguments at all.
    @MainActor
    func testDemoIsReachableByTappingFromTheHomeScreen() throws {
        let app = launch()

        let entry = app.buttons["Interview Copilot. Listens, suggests answers, and follows your voice as you read them."]
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "the home screen has no Interview Copilot entry")
        attach(app, "01-home-screen")
        entry.tap()

        XCTAssertTrue(app.staticTexts["Interview Copilot"].waitForExistence(timeout: 5))
        attach(app, "02-copilot-start")

        // The sample project must never be presented as the owner's own documents. It sits below the
        // two mode cards, so scroll to it rather than assuming it is on screen.
        let sampleNote = app.staticTexts["Sample project — not your documents"]
        if !sampleNote.exists { app.swipeUp() }
        XCTAssertTrue(sampleNote.waitForExistence(timeout: 5), "the start screen does not say the project is a sample")
        if !app.buttons["Start demo, DEMO mode"].isHittable { app.swipeDown() }

        app.buttons["Start demo, DEMO mode"].tap()

        // The scripted interview's first question arrives a few seconds in.
        let questionHeader = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Question 1'")).firstMatch
        XCTAssertTrue(questionHeader.waitForExistence(timeout: 30), "no card appeared in the demo")
        attach(app, "03-demo-first-card")

        // The mode badge is unmistakable, and the fake provider says so.
        XCTAssertTrue(app.staticTexts["DEMO"].exists || app.otherElements["DEMO mode"].exists)

        // Wait for more cards, then check the reader was not dragged off the card it was on.
        let latest = app.buttons["Latest"]
        XCTAssertTrue(latest.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: latest)
        waitForExpectations(timeout: 40)
        XCTAssertTrue(questionHeader.exists, "a newly detected question stole focus from the card being read")
        attach(app, "04-demo-newer-question-waiting")

        // Navigate forward and back; the first card is still there with its own state.
        app.buttons["Next"].tap()
        let secondHeader = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Question 2'")).firstMatch
        XCTAssertTrue(secondHeader.waitForExistence(timeout: 10))
        attach(app, "05-demo-second-card")
        app.buttons["Previous"].tap()
        XCTAssertTrue(questionHeader.waitForExistence(timeout: 10), "returning to the first card lost it")

        // Ending the session releases the microphone and returns to the ordinary app.
        app.buttons["End interview session"].tap()
        XCTAssertTrue(app.staticTexts["Interview Copilot"].waitForExistence(timeout: 10))
        attach(app, "06-after-ending-session")
    }

    /// The French demo produces cards too — evaluation scope, not a claim of French support.
    @MainActor
    func testFrenchDemoProducesCards() throws {
        let app = launch()
        app.buttons["Interview Copilot. Listens, suggests answers, and follows your voice as you read them."].tap()
        XCTAssertTrue(app.staticTexts["Interview Copilot"].waitForExistence(timeout: 5))

        app.buttons["Français"].tap()
        attach(app, "07-french-start")
        app.buttons["Start demo, DEMO mode"].tap()

        let questionHeader = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Question 1'")).firstMatch
        XCTAssertTrue(questionHeader.waitForExistence(timeout: 30), "no card appeared in the French demo")
        attach(app, "08-french-first-card")
    }

    /// Live must report honestly when it cannot run, and must never fall back to canned answers.
    @MainActor
    func testLiveStateIsReportedHonestlyWhenUnconfigured() throws {
        let app = XCUIApplication()
        // No backend configured in a fresh simulator install.
        app.launchArguments += ["-CopilotBackendURL", "", "-CopilotBackendToken", ""]
        app.launch()

        app.buttons["Interview Copilot. Listens, suggests answers, and follows your voice as you read them."].tap()
        XCTAssertTrue(app.staticTexts["Interview Copilot"].waitForExistence(timeout: 5))

        let live = app.buttons["Start live, LIVE mode"]
        XCTAssertTrue(live.waitForExistence(timeout: 5))
        XCTAssertFalse(live.isEnabled, "Live was offered without a configured backend")
        XCTAssertTrue(app.staticTexts["No backend is configured — answer suggestions are unavailable"].exists,
                      "the reason Live is unavailable is not shown")
        attach(app, "09-live-unconfigured")
    }

    /// The ordinary teleprompter is still one tap away and still works.
    @MainActor
    func testScriptReadingIsStillReachable() throws {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Scripts"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["New script"].exists || app.staticTexts["Paste your first script."].exists)
        attach(app, "10-scripts-intact")
    }
}
