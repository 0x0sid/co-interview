import XCTest

/// Screenshots of the v2.5 interview screen, driven by taps through the demo.
///
/// Writes PNGs to `/tmp/v25-*.png` so they can be collected into the evidence folder without
/// unpacking an `.xcresult`. Run once per appearance (`xcrun simctl ui booted appearance dark`),
/// passing `CAPTURE_SUFFIX` to name the files.
///
/// Everything captured is synthetic: an invented candidate answering invented questions, and — in
/// the Context shot — placeholder thumbnails drawn by the app itself, never anyone's photos.
final class InterviewScreenCaptureTests: XCTestCase {
    private var suffix: String {
        ProcessInfo.processInfo.environment["CAPTURE_SUFFIX"] ?? "light"
    }

    private func save(_ app: XCUIApplication, _ name: String) {
        let shot = app.screenshot()
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/v25-\(name)-\(suffix).png"))
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "\(name)-\(suffix)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The page currently holds a *finished* answer.
    ///
    /// Not the Follow-ups link, which only a detected question carries, and not a phrase from a demo
    /// answer, which would tie the test to fixture wording. `AnswerPageView` publishes this the
    /// moment the answer it is showing completes.
    private func answerComplete(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "answer-complete").firstMatch
    }

    /// Opens the demo interview, verifying each step actually happened.
    ///
    /// Both taps used to be fire-and-forget. A tap that does not register is indistinguishable from
    /// a slow screen until a later assertion fails for the wrong reason — which is exactly how these
    /// captures failed: "Failed to tap Start demo, DEMO mode: No matches found", because the start
    /// screen had not opened yet or the button sat below the fold behind the two mode cards.
    private func openDemo(_ app: XCUIApplication) {
        let entry = app.buttons["Interview Copilot. Listens, suggests answers, and follows your voice as you read them."]
        XCTAssertTrue(entry.waitForExistence(timeout: 20), "the home screen has no Interview Copilot entry")

        let startDemo = app.buttons["Start demo, DEMO mode"]
        for _ in 0..<3 where !startDemo.exists {
            entry.tap()
            _ = startDemo.waitForExistence(timeout: 8)
        }
        XCTAssertTrue(startDemo.waitForExistence(timeout: 10), "the Copilot start screen never opened")

        // Arrival on the interview screen, not just a tap that was sent.
        //
        // Matched on either transcript label: one fixture launches with the strip already expanded,
        // where the button reads "Collapse live transcript" and waiting for "Expand" waits forever.
        let onInterview = app.buttons.matching(
            NSPredicate(format: "label ENDSWITH 'live transcript'")
        ).firstMatch
        for _ in 0..<3 where !onInterview.exists {
            if !startDemo.isHittable { app.swipeDown() }
            if startDemo.isHittable { startDemo.tap() }
            _ = onInterview.waitForExistence(timeout: 8)
        }
        XCTAssertTrue(onInterview.waitForExistence(timeout: 15), "the demo interview screen never opened")
    }

    /// Collapsed transcript, a generated answer, simulated reading, and the ready chip.
    @MainActor
    func testCaptureInterviewStates() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestsQuietMotion"]
        app.launch()
        openDemo(app)

        // 1 · Collapsed — two transcript lines, a detected question, no answer yet.
        let question = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Question 1'")).firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: 60), "no question page appeared")
        save(app, "01-collapsed")

        // 2 · An answer, produced by pressing Generate.
        let generate = app.buttons["Generate an answer"]
        XCTAssertTrue(generate.waitForExistence(timeout: 10))
        generate.tap()
        XCTAssertTrue(answerComplete(app).waitForExistence(timeout: 30), "no answer arrived after Generate")
        save(app, "02-answer")

        // 3 · Simulated reading midway — the fade starts after the reveal finishes.
        sleep(7)
        save(app, "03-simulated-reading")

        // 4 · A later question's answer, ready but not shown: generate for it, then step back.
        XCTAssertTrue(app.buttons["Next question"].waitForExistence(timeout: 60))
        app.buttons["Next question"].tap()
        if app.buttons["Generate an answer"].waitForExistence(timeout: 10) {
            app.buttons["Generate an answer"].tap()
            app.buttons["Previous question"].tap()                      // walk away while it writes
            // Any entry, not a fixed number: Generate appends its own tab, so which index finishes
            // behind the reader depends on how many entries exist by then. What is being captured is
            // that *some* answer became ready on a page they are not looking at.
            let chip = app.buttons.matching(NSPredicate(format: "label CONTAINS 'is ready'")).firstMatch
            if chip.waitForExistence(timeout: 30) {
                save(app, "04-ready-chip")
            } else {
                save(app, "04-ready-chip-MISSING")
                XCTFail("the ready chip never appeared")
            }
        }
    }

    /// The expanded transcript with a full Context panel — note plus five thumbnails.
    @MainActor
    func testCaptureExpandedContext() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestsQuietMotion", "-InterviewSyntheticContextImages", "5"]
        app.launch()
        openDemo(app)

        XCTAssertTrue(app.staticTexts["5/5 images"].waitForExistence(timeout: 30),
                      "the context panel did not show five images")
        save(app, "05-expanded-context")
    }

    /// The transcript expanded on its own — **without** Context opening with it.
    ///
    /// This is the state the answer used to lose: expanding two lines of transcript also opened the
    /// note and the attachments, and between them they took most of the screen. Expanded transcript
    /// is now bounded and scrolls inside itself, and Context stays shut until it is asked for.
    @MainActor
    func testCaptureExpandedTranscriptKeepsTheAnswer() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestsQuietMotion"]
        app.launch()
        openDemo(app)

        let question = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Question 1'")).firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: 60), "no question page appeared")

        let generate = app.buttons["Generate an answer"]
        XCTAssertTrue(generate.waitForExistence(timeout: 10))
        generate.tap()
        XCTAssertTrue(answerComplete(app).waitForExistence(timeout: 30), "no answer arrived")
        save(app, "06-collapsed-with-answer")

        let expand = app.buttons["Expand live transcript"]
        XCTAssertTrue(expand.waitForExistence(timeout: 10))
        expand.tap()

        // Context must still be shut: expanding the transcript is not a request to open it.
        XCTAssertTrue(app.buttons["Collapse live transcript"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["5/5 images"].exists, "Context opened itself with the transcript")
        save(app, "07-expanded-transcript")
    }

    /// The finished answer, its emphasised keywords, and the follow-up actions under it.
    ///
    /// The chips sit below the answer, so this scrolls to them: a screenshot taken at the top of the
    /// page would show the feature only by its absence.
    @MainActor
    func testCaptureAnswerKeywordsAndFollowUpActions() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestsQuietMotion"]
        app.launch()
        openDemo(app)

        let question = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Question 1'")).firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: 60), "no question page appeared")

        let generate = app.buttons["Generate an answer"]
        XCTAssertTrue(generate.waitForExistence(timeout: 10))
        generate.tap()
        XCTAssertTrue(answerComplete(app).waitForExistence(timeout: 30), "no answer arrived")
        save(app, "09-answer-with-keywords")

        // Scroll to the follow-up chips under the answer.
        //
        // Asserted on a chip, not on the row's container: which chips appear depends on what the
        // answer contains, but every one of them is a button with one of these labels.
        let titles = ["Explain the code", "Give an example", "Go deeper", "Make it shorter"]
        let anyChip = app.buttons.matching(
            NSPredicate(format: "label IN %@", titles)
        ).firstMatch
        XCTAssertTrue(anyChip.waitForExistence(timeout: 10),
                      "a finished answer offered no follow-up actions")

        // Scrolled until the chip is **hittable**, not merely present. An element below the fold is
        // already in the hierarchy, so stopping at `exists` left it off-screen — which both failed
        // the tap check and produced a screenshot of the top of the page.
        for _ in 0..<8 where !anyChip.isHittable { app.swipeUp() }
        XCTAssertTrue(anyChip.isHittable,
                      "a follow-up chip could not be scrolled clear of the floating toolbar")
        save(app, "10-follow-up-actions")

        XCTAssertFalse(anyChip.label.isEmpty, "a follow-up chip has no label")
    }

    /// The end of a long answer can be scrolled out from under the floating toolbar.
    ///
    /// The pill floats over the page, so the bottom of the content is only reachable because the
    /// scroll view carries `pillClearance` of extra bottom padding. Without it the last line of an
    /// answer — and a code card at the end of one — sit under the pill permanently, and no amount of
    /// scrolling brings them out. That is invisible to a screenshot taken at the top of the page,
    /// which is why it is asserted on geometry here rather than eyeballed.
    @MainActor
    func testAnswerEndClearsTheFloatingToolbar() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestsQuietMotion"]
        app.launch()
        openDemo(app)

        let question = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Question 1'")).firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: 60), "no question page appeared")

        let generate = app.buttons["Generate an answer"]
        XCTAssertTrue(generate.waitForExistence(timeout: 10))
        generate.tap()
        XCTAssertTrue(answerComplete(app).waitForExistence(timeout: 30), "no answer arrived")

        // The demo answer that Generate resolves carries code, so this also proves a code card can
        // be brought clear, not just prose.
        let code = app.buttons["Copy code"].firstMatch
        XCTAssertTrue(code.waitForExistence(timeout: 10), "the generated answer showed no code card")

        // Scroll to the very bottom of the answer.
        let page = app.scrollViews.firstMatch
        for _ in 0..<8 { page.swipeUp() }

        let toolbar = app.buttons["Generate an answer for this question"].firstMatch
        let pill = toolbar.exists ? toolbar : app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Generate'")).firstMatch
        guard pill.exists else { return XCTFail("the floating toolbar was not found") }

        let answer = answerComplete(app)
        XCTAssertTrue(answer.exists, "the answer disappeared while scrolling")
        // The answer's own bottom edge must be able to come to rest above the pill's top edge.
        XCTAssertLessThanOrEqual(
            answer.frame.maxY, pill.frame.minY + 1,
            "the end of the answer stays trapped under the floating toolbar"
        )
        save(app, "08-answer-end-clears-toolbar")
    }
}
