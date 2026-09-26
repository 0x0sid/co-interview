import XCTest

/// Screens from the **real** Live pipeline — the configured backend and its real answer model —
/// driven by scripted speech instead of the microphone (`-LiveScriptedSpeech`).
///
/// Opt-in: set `COINTERVIEW_LIVE_UI=1` (as `TEST_RUNNER_COINTERVIEW_LIVE_UI=1` for `xcodebuild`).
/// These make real, billed provider calls and depend on the network and on the model's wording, so
/// the ordinary regression gate never runs them. What they assert is structural — an answer
/// arrived, the note was used, the recovery chip was offered — and the screenshots are the evidence.
@MainActor
final class LiveProviderCaptureTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["COINTERVIEW_LIVE_UI"] == "1" else {
            throw XCTSkip("real-provider capture: set COINTERVIEW_LIVE_UI=1 to run")
        }
    }

    private func save(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launchLive(speech: [String], interval: Int = 3, appearance: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        if let appearance { app.launchArguments += ["-UITestsAppearance", appearance] }
        app.launchArguments += ["-UITestsQuietMotion",
                                "-LiveScriptedSpeech", speech.joined(separator: "||"),
                                "-LiveScriptedSpeechInterval", String(interval)]
        app.launch()
        XCTAssertTrue(app.waitForNeverblankHome(), "Neverblank did not open on its home screen")
        let startLive = app.buttons["Start interview, LIVE mode"]
        XCTAssertTrue(startLive.waitForExistence(timeout: 15), "Live is not offered — is the backend configured and reachable?")
        // Readiness is checked asynchronously; Live becomes tappable once it passes.
        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: startLive)
        wait(for: [enabled], timeout: 20)
        if !startLive.isHittable { app.swipeUp() }
        startLive.tap()
        // First Live on this simulator: the one-time AI consent.
        if app.buttons["ai-consent-agree"].waitForExistence(timeout: 3) { app.buttons["ai-consent-agree"].tap() }
        XCTAssertTrue(app.buttons["Generate an answer"].waitForExistence(timeout: 15), "the Live interview never opened")
        return app
    }

    private func waitForTranscript(_ app: XCUIApplication, containing text: String, timeout: TimeInterval = 30) {
        let line = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: timeout), "the transcript never showed “\(text)”")
    }

    private func answerComplete(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "answer-complete").firstMatch
    }

    private func answerText(_ app: XCUIApplication) -> String {
        app.staticTexts.allElementsBoundByIndex.map { $0.label }.joined(separator: " ")
    }

    /// The note is typed with the keyboard still up and Generate is pressed straight away.
    func testTheNoteGroundsAPersonalAnswer() throws {
        let app = launchLive(speech: ["Could you tell me your secret, in fact?"])
        waitForTranscript(app, containing: "secret")

        app.buttons["Expand live transcript"].tap()
        let context = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Context'")).firstMatch
        XCTAssertTrue(context.waitForExistence(timeout: 5))
        let field = app.textFields["Anything the answers should know"]
        if !field.exists { context.tap() }
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Secret: I love pizza")
        save(app, "live-1-note-typed-keyboard-open")

        app.buttons["Generate an answer"].tap()
        XCTAssertTrue(answerComplete(app).waitForExistence(timeout: 45), "no answer arrived")
        XCTAssertTrue(answerText(app).localizedCaseInsensitiveContains("pizza"), "the answer did not use the note")
        save(app, "live-2-note-grounded-answer")
    }

    /// Four lines, one Generate: the comparison keeps every version.
    func testACompoundComparisonKeepsItsScope() throws {
        let app = launchLive(speech: [
            "Could you compare Java 8 and Java 9?",
            "And Java 7.",
            "Could you compare Java 9 and Java 8 and Java 7?",
            "Java 10.",
        ])
        waitForTranscript(app, containing: "Java 10", timeout: 40)

        app.buttons["Generate an answer"].tap()
        XCTAssertTrue(answerComplete(app).waitForExistence(timeout: 45), "no answer arrived")
        let text = answerText(app)
        for version in ["7", "8", "9", "10"] {
            XCTAssertTrue(text.contains("Java \(version)") || text.contains(" \(version)"), "Java \(version) was dropped")
        }
        save(app, "live-3-comparison")

        app.swipeUp()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "follow-up-actions").firstMatch.waitForExistence(timeout: 5))
        save(app, "live-4-comparison-end-and-follow-ups")

        app.swipeDown()
        app.buttons["Expand live transcript"].tap()
        XCTAssertTrue(app.buttons["Collapse live transcript"].waitForExistence(timeout: 5))
        // Past the expand animation, so the screenshot shows where the strip settles.
        let settled = expectation(description: "expand animation")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
        save(app, "live-5-short-transcript-expanded")
    }

    /// A streamed Java example lands in the code card — monospaced, indented, with its copy button —
    /// and the explanation around it stays prose.
    func testAStreamedJavaExampleRendersAsACodeCard() throws {
        let app = launchLive(speech: ["Show me a Java example of a lambda that sorts a list of strings."])
        waitForTranscript(app, containing: "lambda")
        app.buttons["Generate an answer"].tap()
        XCTAssertTrue(answerComplete(app).waitForExistence(timeout: 45), "no answer arrived")
        save(app, "live-8-java-code-card")
        let copy = app.buttons["Copy code"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "the example did not become a code card")
        // Code text may exist — inside the card. What must not exist is code *in the answer's prose*:
        // prose paragraphs are the answer's other text elements, and none may contain a Java statement.
        let codeLike = NSPredicate(format: "label CONTAINS 'import java' OR label CONTAINS 'public static void'")
        let codeTexts = app.staticTexts.matching(codeLike).allElementsBoundByIndex
        let report = codeTexts.map { "\($0.label.prefix(40)) @ \($0.frame)" }.joined(separator: "\n") + "\ncopy button @ \(copy.frame)"
        let attachment = XCTAttachment(string: report)
        attachment.name = "code-text-positions"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertLessThanOrEqual(codeTexts.count, 1, "code appears in more than one text element — some of it is prose")
    }

    /// Ultra Contrast on a real answer with prose, emphasised keywords and a code card.
    func testUltraContrastAnswerWithCode() throws {
        let app = launchLive(speech: ["Show me a Java example of a lambda that sorts a list of strings."], appearance: "ultraContrast")
        waitForTranscript(app, containing: "lambda")
        app.buttons["Generate an answer"].tap()
        XCTAssertTrue(answerComplete(app).waitForExistence(timeout: 45), "no answer arrived")
        save(app, "ultra-1-answer-with-code")
        XCTAssertTrue(app.buttons["Copy code"].firstMatch.waitForExistence(timeout: 5), "the example did not become a code card")
        app.swipeUp()
        save(app, "ultra-2-scrolled-clear-of-toolbar")
    }

    /// With no note, the answer asks for the detail and the page offers Add context, not elaboration.
    func testAMissingDetailOffersAddContext() throws {
        let app = launchLive(speech: ["Could you tell me your secret, in fact?"])
        waitForTranscript(app, containing: "secret")

        app.buttons["Generate an answer"].tap()
        XCTAssertTrue(answerComplete(app).waitForExistence(timeout: 45), "no answer arrived")
        let addContext = app.buttons["Add context"]
        XCTAssertTrue(addContext.waitForExistence(timeout: 5), "no Add context recovery was offered")
        XCTAssertFalse(app.buttons["Give an example"].exists)
        save(app, "live-6-missing-detail-add-context")

        addContext.tap()
        XCTAssertTrue(app.textFields["Anything the answers should know"].waitForExistence(timeout: 5))
        save(app, "live-7-add-context-opens-note")
    }
}
