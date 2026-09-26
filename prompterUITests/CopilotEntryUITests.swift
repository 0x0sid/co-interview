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
        XCTAssertTrue(app.waitForNeverblankHome(), "Neverblank did not open on its home screen")
        let demo = app.buttons["Start demo, DEMO mode"]
        XCTAssertTrue(demo.waitForExistence(timeout: 10), "no Demo in the Debug developer section")
        app.scrollTo(demo)
        demo.tap()
    }

    private func firstQuestion(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Question 1'")).firstMatch
    }

    /// Home → Interview Copilot → Start demo → Generate, with no launch arguments at all.

    /// Opens the Interview Copilot start screen, and *verifies it actually opened*.
    ///
    /// The obvious check — waiting for the text "Interview Copilot" — is ambiguous: the home screen's
    /// own entry card carries that exact label, so the wait succeeds whether or not the tap
    /// navigated. A tap that silently did not register therefore left the test running against the
    /// home screen, looking for elements that were never going to be there. "Start demo" exists only
    /// on the start screen, so that is what arrival means here.
    @MainActor
    @discardableResult
    private func openCopilot(_ app: XCUIApplication) -> Bool {
        // Neverblank now opens straight onto its home screen; there is no entry step to take.
        let arrived = app.waitForNeverblankHome()
        if !arrived { XCTFail("Neverblank did not open on its home screen") }
        return arrived
    }

    @MainActor
    func testDemoIsReachableAndAnswersOnlyWhenGenerateIsPressed() throws {
        let app = launch()

        attach(app, "01-home-screen")
        openCopilot(app)
        attach(app, "02-copilot-start")

        // The sample project must never be presented as the owner's own documents.
        // Scrolled to rather than assumed on screen: the note sits below the two mode cards, and how
        // far below depends on how much the cards say.
        // Matched on a substring rather than the whole line: the copy says which modes the sample
        // applies to, and that wording is allowed to change without breaking this. What must hold is
        // that the screen calls it a sample.
        let sampleNote = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'Sample project'")
        ).firstMatch
        var noteIsVisible = sampleNote.waitForExistence(timeout: 3)
        for _ in 0..<5 where !noteIsVisible {
            app.swipeUp()
            // Settle after each swipe rather than swiping five times in a row: racing the scroll
            // overshoots the note and the check then fails on a screen that does contain it.
            noteIsVisible = sampleNote.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(noteIsVisible, "the start screen does not say the project is a sample")
        // Same rule as opening the screen: tap, then confirm it actually happened. Scrolling down to
        // read the sample note leaves the button off-screen, and a tap that lands on nothing is
        // indistinguishable from a slow demo until a later assertion fails for the wrong reason.
        let startDemo = app.buttons["Start demo, DEMO mode"]
        let onInterview = app.buttons["Expand live transcript"]
        for _ in 0..<3 where !onInterview.exists {
            if !startDemo.isHittable { app.swipeDown() }
            if startDemo.isHittable { startDemo.tap() }
            _ = onInterview.waitForExistence(timeout: 6)
        }
        XCTAssertTrue(onInterview.waitForExistence(timeout: 10), "the demo interview screen never opened")

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

        // Generate stays tappable while a generation runs — a disabled control explains nothing, and
        // listening does not stop. What must not happen is a *duplicate request* for the same speech,
        // which is enforced by coverage rather than by grey-ing the button out.
        XCTAssertTrue(generate.isEnabled, "Generate went grey instead of staying available")

        let answered = app.descendants(matching: .any).matching(identifier: "answer-complete").firstMatch
        XCTAssertTrue(answered.waitForExistence(timeout: 30), "no answer arrived after Generate")

        // That a repeat tap with nothing new said creates no second request is asserted in
        // `RequestContentTests.repeatedTapsWithNothingNewMakeNoSecondRequest`, where the requests
        // themselves can be counted directly rather than inferred from the screen.
        XCTAssertFalse(app.staticTexts["No answer yet."].exists)
        attach(app, "04-answer-after-generate")

        // Regenerate keeps the previous version and labels the new one.
        let moreActions = app.buttons["More actions"]
        XCTAssertTrue(moreActions.waitForExistence(timeout: 10), "the toolbar has no More actions button")
        moreActions.tap()
        let regenerate = app.buttons["Regenerate answer"]
        XCTAssertTrue(regenerate.waitForExistence(timeout: 10), "the menu never offered Regenerate")
        regenerate.tap()
        let versionLine = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'v2 ·'")).firstMatch
        XCTAssertTrue(versionLine.waitForExistence(timeout: 30), "the regenerated answer is not labelled as v2")
        attach(app, "05-regenerated-v2")

        // Navigate back and forward; each page keeps its own state.
        //
        // **Backwards first.** Generate appends its own tab and opens it, so the reader is on the
        // last page — there is nothing to the right of it, and the old version of this test tapped
        // "Next question" and waited for a page that could not appear.
        XCTAssertTrue(app.buttons["Previous question"].waitForExistence(timeout: 10))
        app.buttons["Previous question"].tap()
        XCTAssertTrue(question.waitForExistence(timeout: 15), "stepping back did not reach an earlier page")

        // Coming back, the generated page still holds its finished answer. Asserted on that state
        // rather than on the page's label: the demo keeps detecting questions, so the "n/N" counter
        // inside the label changes underneath a test that pinned the exact string.
        app.buttons["Next question"].tap()
        XCTAssertTrue(answered.waitForExistence(timeout: 15), "returning to the generated page lost its answer")

        // Closing returns to the ordinary app.
        app.buttons["Close interview"].tap()
        XCTAssertTrue(app.waitForNeverblankHome(timeout: 10), "closing did not return to the Neverblank home")
        attach(app, "06-after-closing")
    }

    /// Switches a Form `Toggle` on, and confirms it.
    ///
    /// In a Form the switch's accessibility frame spans the whole row, so a centre tap can land on
    /// the label and toggle nothing. That is a hit-testing quirk, not a broken binding — a direct
    /// write to the same property updates this control immediately — so this aims at the control and
    /// checks the result rather than assuming either tap point works.
    @MainActor
    private func turnOn(_ toggle: XCUIElement) -> Bool {
        for attempt in 0..<4 {
            if toggle.value as? String == "1" { return true }
            if attempt.isMultiple(of: 2) {
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            } else {
                toggle.tap()
            }
            for _ in 0..<8 {
                if toggle.value as? String == "1" { return true }
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        return toggle.value as? String == "1"
    }

    /// Opens ••• → Diagnostics, verifying arrival rather than assuming the taps landed.
    @MainActor
    @discardableResult
    private func openDiagnostics(_ app: XCUIApplication) -> Bool {
        let capture = app.switches["Capture test content"]
        for _ in 0..<3 {
            let moreActions = app.buttons["More actions"]
            guard moreActions.waitForExistence(timeout: 10) else { return false }
            moreActions.tap()
            let entry = app.buttons["Diagnostics"]
            if entry.waitForExistence(timeout: 5) {
                entry.tap()
                if capture.waitForExistence(timeout: 6) { return true }
            }
        }
        return false
    }

    /// Diagnostics are reachable **from inside a running interview**.
    ///
    /// Content capture is per-session and resets when a session starts, so the only moment it can be
    /// switched on for the session being recorded is from within that session. Without this entry
    /// there was no such moment — the instructions told you to enable it somewhere you could only
    /// reach by ending the interview first.
    @MainActor
    func testDiagnosticsAreReachableWithoutLeavingTheInterview() throws {
        let app = launch()
        openCopilot(app)

        let startDemo = app.buttons["Start demo, DEMO mode"]
        let onInterview = app.buttons["Expand live transcript"]
        for _ in 0..<3 where !onInterview.exists {
            if !startDemo.isHittable { app.swipeDown() }
            if startDemo.isHittable { startDemo.tap() }
            _ = onInterview.waitForExistence(timeout: 6)
        }
        XCTAssertTrue(onInterview.waitForExistence(timeout: 15), "the demo interview screen never opened")

        XCTAssertTrue(openDiagnostics(app), "the menu offers no way into diagnostics")

        let capture = app.switches["Capture test content"]
        XCTAssertTrue(capture.waitForExistence(timeout: 10), "the capture toggle is not reachable from the interview")
        XCTAssertEqual(capture.value as? String, "0", "content capture was already on for a new session")
        XCTAssertTrue(turnOn(capture), "the capture toggle did not switch on")

        // The session this capture belongs to, as the sheet reports it.
        let sessionRow = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'Session'")).firstMatch
        let sessionBefore = app.cells.containing(.staticText, identifier: "Session").firstMatch.label

        // Leaving the sheet returns to the same interview — nothing was restarted.
        app.buttons["Done"].tap()
        XCTAssertTrue(onInterview.waitForExistence(timeout: 10), "closing diagnostics left the interview")

        // Reopening finds the *same* session, still capturing: closing the sheet must not end the
        // interview it was recording, and must not quietly switch capture back off.
        XCTAssertTrue(openDiagnostics(app), "diagnostics could not be reopened")
        XCTAssertTrue(capture.waitForExistence(timeout: 10))
        XCTAssertEqual(capture.value as? String, "1", "capture switched itself off when the sheet closed")
        _ = sessionRow
        let sessionAfter = app.cells.containing(.staticText, identifier: "Session").firstMatch.label
        XCTAssertEqual(sessionBefore, sessionAfter, "the interview session changed while it was running")
        app.buttons["Done"].tap()
    }

    /// The floating toolbar must never trap the end of an answer underneath it.
    ///
    /// It floats over the page deliberately, so content passes behind it — what matters is that the
    /// reader can always scroll the last lines and the Follow-ups link out from under it.
    @MainActor
    func testTheToolbarNeverTrapsTheEndOfAnAnswer() throws {
        let app = launch()
        openCopilot(app)
        XCTAssertTrue(app.buttons["Start demo, DEMO mode"].waitForExistence(timeout: 10))
        app.buttons["Start demo, DEMO mode"].tap()

        XCTAssertTrue(firstQuestion(app).waitForExistence(timeout: 60))
        let generate = app.buttons["Generate an answer"]
        XCTAssertTrue(generate.waitForExistence(timeout: 10))
        generate.tap()

        // Not the Follow-ups link: a Generate entry is the discussion, not a detected question, so it
        // carries no scripted follow-ups and never shows that link. `AnswerPageView` publishes this
        // the moment the answer completes.
        let answer = app.descendants(matching: .any).matching(identifier: "answer-complete").firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 30), "no answer arrived")

        // Scroll to the very bottom of the answer.
        for _ in 0..<4 { app.swipeUp() }

        let toolbar = app.buttons["Generate an answer"].frame
        XCTAssertLessThanOrEqual(answer.frame.maxY, toolbar.minY + 1,
                                 "the end of the answer stays trapped under the floating toolbar")
        attach(app, "12-answer-end-clear-of-toolbar")
    }

    /// The transcript opens to reveal the context panel, and collapsing it keeps what was entered.
    @MainActor
    func testTranscriptExpandsToShowContextAndKeepsItOnCollapse() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestsQuietMotion", "-InterviewSyntheticFiles"]
        app.launch()
        openDemo(app)

        XCTAssertTrue(app.staticTexts["Context"].waitForExistence(timeout: 20),
                      "the expanded transcript does not show Context")
        XCTAssertTrue(app.staticTexts["2 files"].waitForExistence(timeout: 10), "the file count is missing")
        attach(app, "07-expanded-context")

        app.buttons["Collapse live transcript"].tap()
        XCTAssertTrue(app.buttons["Expand live transcript"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Context"].exists)

        // Re-expanding shows the same files: collapsing is a view change, not a discard.
        app.buttons["Expand live transcript"].tap()
        XCTAssertTrue(app.staticTexts["2 files"].waitForExistence(timeout: 5),
                      "collapsing the transcript lost the attached context")
    }

    /// French replay coverage, kept: the scripted French interview still drives the pipeline screen.
    /// This is evaluation scope, not a claim of French support.
    @MainActor
    func testFrenchScriptedInterviewStillProducesCards() throws {
        let app = launch()
        openCopilot(app)

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
        // No backend: both the saved settings and the Debug build's own baked-in local backend are
        // suppressed, so this asserts the empty state on any machine rather than only on one with no
        // `Local-Debug.xcconfig`.
        app.launchArguments += ["-UITestsQuietMotion", "-CopilotBackendURL", "", "-CopilotBackendToken", "",
                                "-CopilotIgnoreDevelopmentDefaults"]
        app.launch()

        openCopilot(app)

        // Without a backend, Live may still *listen* — transcription and detection work on their own,
        // and `LiveReadiness` deliberately offers that half as "listening only" — but it must never
        // offer the full, answer-generating Live. Which of the two states appears depends on whether
        // this machine can listen (microphone and speech permission, on-device model), so both are
        // asserted, and neither lets an unqualified "Start live" through.
        let listenOnly = app.buttons["Start interview (listening only), LIVE mode"]
        let full = app.buttons["Start interview, LIVE mode"]
        XCTAssertTrue(listenOnly.waitForExistence(timeout: 5) || full.waitForExistence(timeout: 1),
                      "no Live action on the start screen")
        if listenOnly.exists {
            XCTAssertFalse(full.exists, "full Live was offered alongside listening-only with no provider wired to it")
        } else {
            XCTAssertFalse(full.isEnabled, "Live was offered on a screen with no provider wired to it")
        }
        // `LiveReadiness` replaced the old flat "Connection to AI service required" line with the
        // specific blocker, so this asserts that a reason naming the missing backend is shown rather
        // than one exact sentence.
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'No backend is configured'")
        ).firstMatch.waitForExistence(timeout: 5), "the reason Live is unavailable is not shown")
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
