import XCTest

/// The same Java-vs-Python answer, captured for design review: `-UITestsAnswerSample plain` (one
/// paragraph) or `structured` (lead, bullets, emphasis). Set ANSWER_SAMPLE / ANSWER_APPEARANCE with the
/// TEST_RUNNER_ prefix. Captures only, plus a check that the answer is on screen.
@MainActor
final class AnswerPresentationCaptureTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = true }

    func testCaptureTheJavaPythonAnswer() throws {
        let environment = ProcessInfo.processInfo.environment
        let sample = environment["ANSWER_SAMPLE"] ?? "structured"
        let appearance = environment["ANSWER_APPEARANCE"] ?? "light"
        let app = XCUIApplication()
        app.launchArguments += ["-UITestsQuietMotion", "-NeverblankDeveloperTools", "-UITestsAnswerSample", sample,
                                "-UITestsAppearance", appearance]
        app.launch()
        XCTAssertTrue(app.waitForNeverblankHome())
        let demo = app.buttons["Start demo, DEMO mode"]
        app.scrollTo(demo)
        demo.tap()
        XCTAssertTrue(app.staticTexts["No answer yet."].waitForExistence(timeout: 60), "the question page never appeared")
        let generate = app.buttons["Generate an answer for this question"]
        XCTAssertTrue(generate.waitForExistence(timeout: 10))
        generate.tap()
        let answered = app.descendants(matching: .any).matching(identifier: "answer-complete").firstMatch
        XCTAssertTrue(answered.waitForExistence(timeout: 30), "no answer arrived after Generate")
        sleep(1)                                                // let the last layout settle
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "answer-\(sample)-\(appearance)"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "Java")).firstMatch.exists)
    }
}
