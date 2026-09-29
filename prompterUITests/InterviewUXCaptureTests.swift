import XCTest

/// Context typed during an interview, and the home screen's speech-model setup — the checks only a
/// screen can make. Run on a small iPhone (SE) and a regular one. Captures plus layout assertions.
@MainActor
final class InterviewUXCaptureTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = true }

    private func save(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// While context is typed the floating Pause / Generate / More control stays on screen, and neither
    /// it nor the keyboard covers the field or its Add button. One tap adds the text once.
    func testTypingContextKeepsTheControlVisibleAndAddsOnce() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestsQuietMotion"]
        app.launch()
        XCTAssertTrue(app.waitForNeverblankHome())
        let demo = app.buttons["Start demo, DEMO mode"]
        app.scrollTo(demo)
        demo.tap()
        let expand = app.buttons["Expand live transcript"]
        XCTAssertTrue(expand.waitForExistence(timeout: 20))
        expand.tap()
        let context = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Context'")).firstMatch
        XCTAssertTrue(context.waitForExistence(timeout: 5))
        context.tap()

        let field = app.descendants(matching: .any)["context-note-field"]
        let add = app.buttons["add-context"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertFalse(add.isEnabled, "no enabled Add context while the field is empty")
        field.tap()
        field.typeText("   ")
        XCTAssertFalse(add.isEnabled, "whitespace only is not context")
        field.typeText("I led the Kafka migration")
        XCTAssertTrue(add.isEnabled, "Add context enables once there is text")
        save(app, "context-1-typing-keyboard-open")

        let generate = app.buttons["Generate an answer"]
        XCTAssertTrue(generate.exists && generate.isHittable, "the floating control disappeared behind the keyboard")
        XCTAssertTrue(add.isHittable, "the keyboard covers Add context")
        XCTAssertFalse(generate.frame.intersects(field.frame), "the floating control covers the context field")
        XCTAssertFalse(generate.frame.intersects(add.frame), "the floating control covers Add context")

        add.tap()
        XCTAssertTrue(app.descendants(matching: .any)["added-context"].waitForExistence(timeout: 5))
        XCTAssertFalse(add.isEnabled, "the field is cleared: a second tap adds nothing")
        save(app, "context-2-added")
    }

    /// The home screen's speech-model setup, in each state (forced with DEBUG launch arguments).
    func testSpeechModelSetupStatesOnHome() throws {
        let cases: [(String, [String], String)] = [
            ("choose-language", ["-UITestsSpeechModel", "needsDownload", "-UITestsInterviewLanguage", "system"], "speech-setup-choose-language"),
            ("download", ["-UITestsSpeechModel", "needsDownload", "-UITestsInterviewLanguage", "fr-FR"], "speech-setup-download"),
            ("downloading", ["-UITestsSpeechModel", "downloading", "-UITestsInterviewLanguage", "fr-FR"], "speech-setup-progress"),
            ("failed", ["-UITestsSpeechModel", "failed", "-UITestsInterviewLanguage", "fr-FR"], "speech-setup-retry"),
            ("ready", ["-UITestsSpeechModel", "installed"], "start-interview"),
        ]
        for (name, arguments, expected) in cases {
            let app = XCUIApplication()
            app.launchArguments += ["-UITestsQuietMotion"] + arguments
            app.launch()
            XCTAssertTrue(app.waitForNeverblankHome())
            let element = app.descendants(matching: .any)[expected]
            XCTAssertTrue(element.waitForExistence(timeout: 20), "\(name): \(expected) not shown")
            save(app, "home-speech-\(name)")
            if name == "ready" {
                let start = app.buttons["start-interview"]
                XCTAssertTrue(start.isEnabled, "ready: Start Interview is not enabled")
                XCTAssertFalse(app.descendants(matching: .any)["speech-setup"].exists, "ready: the setup card is still shown")
            }
            app.terminate()
        }
    }
}
