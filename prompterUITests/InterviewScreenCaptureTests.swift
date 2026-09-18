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

    private func openDemo(_ app: XCUIApplication) {
        let entry = app.buttons["Interview Copilot. Listens, suggests answers, and follows your voice as you read them."]
        XCTAssertTrue(entry.waitForExistence(timeout: 20))
        entry.tap()
        XCTAssertTrue(app.buttons["Start demo, DEMO mode"].waitForExistence(timeout: 10))
        app.buttons["Start demo, DEMO mode"].tap()
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
        XCTAssertTrue(app.staticTexts["Follow-ups"].waitForExistence(timeout: 30), "no answer arrived after Generate")
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
            let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Question 2 is ready'")).firstMatch
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
}
