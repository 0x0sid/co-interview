import XCTest

/// The owner-facing path, driven by taps only: launch the app normally, find **Interview Copilot** on
/// the home screen, start the demo, and work the screen the way a person would.
///
/// This exists because the copilot was previously reachable only through a launch argument, so a
/// normal launch showed nothing but the teleprompter. A test that used the launch argument would have
/// kept saying "it works" while the owner saw the old screen — so this one navigates the way a person
/// does, and captures screenshots as evidence.
///
/// **It presses Generate.** Waiting for an answer to appear by itself would not test anything: the
/// screen is built so that detection and generation are separate, and an answer that appeared without
/// a tap would be a bug, not a pass.
///
/// Everything it shows is synthetic: an invented candidate answering invented questions.
final class CopilotEntryUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Every launch turns off perpetual motion. XCUITest waits for the app to be idle before each
    /// query, and the listening waveform would otherwise animate forever and hang the query.
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestsQuietMotion"]
        app.launch()
        return app
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openDemo(_ app: XCUIApplication) {
        let entry = app.buttons["Interview Copilot. Listens, suggests answers, and follows your voice as you read them."]
        XCTAssertTrue(entry.waitForExistence(timeout: 15), "the home screen has no Interview Copilot entry")
        entry.tap()
        XCTAssertTrue(app.buttons["Start demo, DEMO mode"].waitForExistence(timeout: 10))
        app.buttons["Start demo, DEMO mode"].tap()
    }

    private func firstQuestion(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Question 1'")).firstMatch
    }

    /// Home → Interview Copilot → Start demo → Generate, with no launch arguments at all.
    @MainActor
    func testDemoIsReachableAndAnswersOnlyWhenGenerateIsPressed() throws {
        let app = launch()

        let entry = app.buttons["Interview Copilot. Listens, suggests answers, and follows your voice as you read them."]
        XCTAssertTrue(entry.waitForExistence(timeout: 15), "the home screen has no Interview Copilot entry")
        attach(app, "01-home-screen")
        entry.tap()

        XCTAssertTrue(app.staticTexts["Interview Copilot"].waitForExistence(timeout: 5))
        attach(app, "02-copilot-start")

        // The sample project must never be presented as the owner's own documents.
        let sampleNote = app.staticTexts["Sample project — not your documents"]
        if !sampleNote.exists { app.swipeUp() }
        XCTAssertTrue(sampleNote.waitForExistence(timeout: 5), "the start screen does not say the project is a sample")
        if !app.buttons["Start demo, DEMO mode"].isHittable { app.swipeDown() }
        app.buttons["Start demo, DEMO mode"].tap()

        // A question is detected on its own — that is what listening does.
        let question = firstQuestion(app)
        XCTAssertTrue(question.waitForExistence(timeout: 60), "no question page appeared")

        // …but no answer is written until someone asks. "No answer yet." is the page's own words.
        XCTAssertTrue(app.staticTexts["No answer yet."].waitForExistence(timeout: 5),
                      "an answer appeared without Generate being pressed")
        attach(app, "03-detected-question-no-answer")

        // The demo must never look like the microphone is open.
        let badge = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Demo'")).firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 5), "the demo is not marked as a demo")

        // Press Generate.
        let generate = app.buttons["Generate an answer"]
        XCTAssertTrue(generate.waitForExistence(timeout: 5))
        generate.tap()

        // Pressing again while it is running must not start a second generation; the button is
        // disabled for exactly that reason.
        XCTAssertFalse(generate.isEnabled, "Generate stayed enabled while a generation was running")

        XCTAssertTrue(app.staticTexts["Follow-ups"].waitForExistence(timeout: 30), "no answer arrived after Generate")
        XCTAssertFalse(app.staticTexts["No answer yet."].exists)
        attach(app, "04-answer-after-generate")

        // Regenerate keeps the previous version and labels the new one.
        app.buttons["More actions"].tap()
        app.buttons["Regenerate answer"].tap()
        let versionLine = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'v2 ·'")).firstMatch
        XCTAssertTrue(versionLine.waitForExistence(timeout: 30), "the regenerated answer is not labelled as v2")
        attach(app, "05-regenerated-v2")

        // Navigate forward and back; each page keeps its own state.
        XCTAssertTrue(app.buttons["Next question"].waitForExistence(timeout: 10))
        app.buttons["Next question"].tap()
        let second = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Question 2'")).firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 15))
        app.buttons["Previous question"].tap()
        XCTAssertTrue(question.waitForExistence(timeout: 10), "returning to the first page lost it")

        // Closing returns to the ordinary app.
        app.buttons["Close interview"].tap()
        XCTAssertTrue(app.staticTexts["Interview Copilot"].waitForExistence(timeout: 10))
        attach(app, "06-after-closing")
    }

    /// The floating toolbar must never trap the end of an answer underneath it.
    ///
    /// It floats over the page deliberately, so content passes behind it — what matters is that the
    /// reader can always scroll the last lines and the Follow-ups link out from under it.
    @MainActor
    func testTheToolbarNeverTrapsTheEndOfAnAnswer() throws {
        let app = launch()
        app.buttons["Interview Copilot. Listens, suggests answers, and follows your voice as you read them."].tap()
        XCTAssertTrue(app.buttons["Start demo, DEMO mode"].waitForExistence(timeout: 10))
        app.buttons["Start demo, DEMO mode"].tap()

        XCTAssertTrue(firstQuestion(app).waitForExistence(timeout: 60))
        let generate = app.buttons["Generate an answer"]
        XCTAssertTrue(generate.waitForExistence(timeout: 10))
        generate.tap()

        let followUps = app.staticTexts["Follow-ups"]
        XCTAssertTrue(followUps.waitForExistence(timeout: 30))

        // Scroll to the very bottom of the answer.
        for _ in 0..<4 where !followUps.isHittable { app.swipeUp() }

        XCTAssertTrue(followUps.isHittable, "Follow-ups could not be scrolled clear of the toolbar")
        let toolbar = app.buttons["Generate an answer"].frame
        XCTAssertFalse(followUps.frame.intersects(toolbar), "Follow-ups sits underneath the Generate button")
        attach(app, "12-answer-end-clear-of-toolbar")
    }

    /// The transcript opens to reveal the context panel, and collapsing it keeps what was entered.
    @MainActor
    func testTranscriptExpandsToShowContextAndKeepsItOnCollapse() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestsQuietMotion", "-InterviewSyntheticContextImages", "5"]
        app.launch()
        openDemo(app)

        XCTAssertTrue(app.staticTexts["Context"].waitForExistence(timeout: 20),
                      "the expanded transcript does not show Context")
        XCTAssertTrue(app.staticTexts["5/5 images"].exists, "the context image counter is missing")
        attach(app, "07-expanded-context")

        app.buttons["Collapse live transcript"].tap()
        XCTAssertTrue(app.buttons["Expand live transcript"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Context"].exists)

        // Re-expanding shows the same note and the same five thumbnails: collapsing is a view
        // change, not a discard.
        app.buttons["Expand live transcript"].tap()
        XCTAssertTrue(app.staticTexts["5/5 images"].waitForExistence(timeout: 5),
                      "collapsing the transcript lost the attached context")
    }

    /// French replay coverage, kept: the scripted French interview still drives the pipeline screen.
    /// This is evaluation scope, not a claim of French support.
    @MainActor
    func testFrenchScriptedInterviewStillProducesCards() throws {
        let app = launch()
        app.buttons["Interview Copilot. Listens, suggests answers, and follows your voice as you read them."].tap()
        XCTAssertTrue(app.staticTexts["Interview Copilot"].waitForExistence(timeout: 5))

        app.buttons["Français"].tap()
        attach(app, "08-french-start")

        // The pipeline prototype is the path that runs detection and generation end to end.
        let openPrototype = app.buttons["Open with the script"]
        if !openPrototype.isHittable { app.swipeUp() }
        XCTAssertTrue(openPrototype.waitForExistence(timeout: 5))
        openPrototype.tap()

        let questionHeader = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Question 1'")).firstMatch
        XCTAssertTrue(questionHeader.waitForExistence(timeout: 40), "no card appeared in the French demo")
        attach(app, "09-french-first-card")
    }

    /// Live must report honestly that it cannot run, and must never fall back to the demo script.
    @MainActor
    func testLiveStateIsReportedHonestlyWhenUnconfigured() throws {
        let app = XCUIApplication()
        // No backend configured in a fresh simulator install.
        app.launchArguments += ["-UITestsQuietMotion", "-CopilotBackendURL", "", "-CopilotBackendToken", ""]
        app.launch()

        app.buttons["Interview Copilot. Listens, suggests answers, and follows your voice as you read them."].tap()
        XCTAssertTrue(app.staticTexts["Interview Copilot"].waitForExistence(timeout: 5))

        let live = app.buttons["Start live, LIVE mode"]
        XCTAssertTrue(live.waitForExistence(timeout: 5))
        XCTAssertFalse(live.isEnabled, "Live was offered on a screen with no provider wired to it")
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'Connection to AI service required'")
        ).firstMatch.exists, "the reason Live is unavailable is not shown")
        attach(app, "10-live-unconfigured")
    }

    /// The ordinary teleprompter is still one tap away and still works.
    @MainActor
    func testScriptReadingIsStillReachable() throws {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Scripts"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["New script"].exists || app.staticTexts["Paste your first script."].exists)
        attach(app, "11-scripts-intact")
    }
}
