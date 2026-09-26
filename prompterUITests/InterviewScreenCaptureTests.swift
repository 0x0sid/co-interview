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
        XCTAssertTrue(app.waitForNeverblankHome(), "Neverblank did not open on its home screen")
        let startDemo = app.buttons["Start demo, DEMO mode"]
        XCTAssertTrue(startDemo.waitForExistence(timeout: 10), "no Demo in the Debug developer section")
        app.scrollTo(startDemo)

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

    /// Session history, the interrupted-session notice, the language selector, and a reopened
    /// interrupted session: content restored, microphone off, Resume offered, nothing re-sent.
    @MainActor
    func testCaptureSessionHistoryAndLanguageSelector() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestsQuietMotion", "-UITestsSeedHistory"]
        app.launch()
        XCTAssertTrue(app.waitForNeverblankHome(), "Neverblank did not open on its home screen")
        XCTAssertTrue(app.staticTexts["An interview was interrupted"].waitForExistence(timeout: 10), "no interrupted-session notice")
        XCTAssertTrue(app.staticTexts["Saved interviews"].exists)
        save(app, "10-start-recent-and-language")

        // History is inline: "All interviews" expands the list in place.
        let row = { (title: String) in app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch }
        XCTAssertFalse(row("Behavioural round").exists, "more than three rows before expanding")
        let expand = app.buttons["All interviews (4)"]
        if !expand.waitForExistence(timeout: 3) { app.swipeUp() }
        XCTAssertTrue(expand.waitForExistence(timeout: 5), "no All interviews control")
        expand.tap()
        XCTAssertTrue(row("Behavioural round").waitForExistence(timeout: 10), "history did not expand")
        save(app, "12-all-interviews")
        app.swipeDown()

        let picker = app.buttons["interview-language"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "no interview language selector")
        picker.tap()
        XCTAssertTrue(app.buttons["Français"].waitForExistence(timeout: 5), "the selector does not offer French")
        save(app, "11-language-selector")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'System language ('")).firstMatch.tap()

        // Open the interrupted interview: content restored, microphone off, Resume offered.
        row("Backend platform interview").tap()
        XCTAssertTrue(app.buttons["Resume interrupted interview"].waitForExistence(timeout: 15), "no explicit Resume on a reopened session")
        XCTAssertTrue(app.descendants(matching: .any)["answer-interrupted"].waitForExistence(timeout: 5), "the partial answer is not labelled interrupted")
        save(app, "13-restored-interrupted-session")

        // Return, then open another one.
        app.buttons["Close interview"].tap()
        XCTAssertTrue(row("System design practice").waitForExistence(timeout: 10), "did not return to the start screen")
        row("System design practice").tap()
        XCTAssertTrue(app.buttons["Resume interview"].waitForExistence(timeout: 15), "reopening a second interview failed")
        app.buttons["Close interview"].tap()
        XCTAssertTrue(row("Entretien architecte cloud").waitForExistence(timeout: 10))

        // Rename.
        let renameTarget = app.buttons["More actions for Demo · Entretien architecte cloud"]
        if !renameTarget.waitForExistence(timeout: 3) { app.swipeUp() }
        renameTarget.tap()
        app.buttons["Rename"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no rename field")
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        field.clearAndType("Renamed interview")
        app.alerts.buttons["Save"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Renamed interview,")).firstMatch.waitForExistence(timeout: 10), "rename did not apply exactly")

        // Delete.
        let more = app.buttons["More actions for Renamed interview"]
        if !more.waitForExistence(timeout: 3) { app.swipeUp() }
        XCTAssertTrue(more.waitForExistence(timeout: 5), "the renamed row has no actions")
        more.tap()
        app.buttons["Delete"].tap()
        app.buttons["Delete interview and its files"].tap()
        let deleted = NSPredicate(format: "exists == false")
        wait(for: [expectation(for: deleted, evaluatedWith: row("Renamed interview"))], timeout: 10)
        save(app, "14-after-rename-and-delete")
    }


    /// The expanded transcript with the Context panel: the note, and "2 files" in place of the old
    /// image counter. Tapping it opens the file list with each file's extraction status.
    @MainActor
    func testCaptureExpandedContext() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestsQuietMotion", "-InterviewSyntheticFiles"]
        app.launch()
        openDemo(app)

        XCTAssertTrue(app.staticTexts["2 files"].waitForExistence(timeout: 30),
                      "the context panel did not show the file count")
        XCTAssertFalse(app.staticTexts["0/5 images"].exists)
        save(app, "05-expanded-context-2-files")

        app.buttons["2 files attached. Show files"].tap()
        XCTAssertTrue(app.staticTexts["demo-notes.txt"].waitForExistence(timeout: 10), "the file list did not open")
        let ready = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Ready'")).firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 20), "no file reached Ready")
        XCTAssertTrue(app.staticTexts[AttachmentsCopy.privacyNote].exists, "the privacy explanation is missing")
        save(app, "05b-files-sheet-extraction-status")
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
        XCTAssertFalse(app.staticTexts["Anything the answers should know"].exists, "Context opened itself with the transcript")
        save(app, "07-expanded-transcript")
    }

    /// Ultra Contrast is a fourth appearance choice beside System, Light and Dark, and the whole
    /// app turns black and white when it is picked. Restores System afterwards.
    @MainActor
    func testUltraContrastIsSelectableInSettings() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestsQuietMotion"]
        app.launch()
        let gear = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Settings'")).firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 20))
        gear.tap()
        let ultra = app.buttons["Ultra"]
        XCTAssertTrue(ultra.waitForExistence(timeout: 10), "no Ultra Contrast choice")
        for name in ["System", "Light", "Dark"] { XCTAssertTrue(app.buttons[name].exists, "\(name) is gone") }
        ultra.tap()
        XCTAssertTrue(ultra.isSelected)
        save(app, "ultra-settings-picker")
        app.buttons["System"].tap()
        XCTAssertTrue(app.buttons["System"].isSelected)
    }

    /// Ultra Contrast in the demo: black and white, keywords bold, and speech-following shown by
    /// underlining spoken words rather than dimming them.
    @MainActor
    func testCaptureUltraContrastReading() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestsQuietMotion", "-UITestsAppearance", "ultraContrast"]
        app.launch()
        openDemo(app)
        let question = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Question 1'")).firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: 60), "no question page appeared")
        let generate = app.buttons["Generate an answer"]
        XCTAssertTrue(generate.waitForExistence(timeout: 10))
        save(app, "ultra-0-listening")
        generate.tap()
        XCTAssertTrue(answerComplete(app).waitForExistence(timeout: 30), "no answer arrived")
        // Give the demo's simulated reading time to follow a few words.
        _ = app.staticTexts["never-appears"].waitForExistence(timeout: 6)
        save(app, "ultra-3-reading-underlined")
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

/// The UI tests cannot import the app; the copy they check is repeated here, verbatim.
enum AttachmentsCopy {
    static let privacyNote = "Files are stored on this device. Relevant text may be sent to the AI service to answer your questions."
}

extension XCUIElement {
    /// Replaces a text field's contents.
    func clearAndType(_ text: String) {
        if let current = value as? String, !current.isEmpty {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 4))
        }
        typeText(text)
    }
}
