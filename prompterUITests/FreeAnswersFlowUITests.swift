import XCTest

/// The first-run funnel on a real (local) backend: a fresh install gets its credential, consents, uses
/// its **2 free AI answers**, sees "Unlock Pro" inline, and the third Generate opens the paywall —
/// with the session intact and no third answer request sent.
///
/// Opt-in: start `backend/` locally with `COINTERVIEW_FAKE=1` and a temporary `ACCESS_DB_PATH`, then
/// run with `TEST_RUNNER_NEVERBLANK_ACCESS_URL=http://127.0.0.1:<port>`. The backend is the fake
/// provider (canned answers, nothing billed); the allowance and its ledger are the real code. The
/// test identity is fresh (`-NeverblankResetAccess`), so no real installation is touched. Purchases
/// are not exercised here.
@MainActor
final class FreeAnswersFlowUITests: XCTestCase {
    private var backendURL = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let url = ProcessInfo.processInfo.environment["NEVERBLANK_ACCESS_URL"], !url.isEmpty else {
            throw XCTSkip("set NEVERBLANK_ACCESS_URL to a local backend to run the free-answers flow")
        }
        backendURL = url
    }

    private func save(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func pause(_ seconds: TimeInterval) {
        let done = expectation(description: "pause")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: seconds + 3)
    }

    private func launch(reset: Bool) -> XCUIApplication {
        let lines = (1...30).map { "Question number \($0), how would you design a rate limiter?" }
        let app = XCUIApplication()
        app.launchArguments += (reset ? ["-NeverblankResetAccess"] : []) + [
            "-CopilotInstallationAuth",
            "-CopilotBackendURL", backendURL,
            "-UITestsQuietMotion",
            "-LiveScriptedSpeech", lines.joined(separator: "||"),
            "-LiveScriptedSpeechInterval", "3",
        ]
        app.launch()
        return app
    }

    private func status(_ app: XCUIApplication) -> String { element(app, "free-answers-status").label }

    /// A fresh test simulator asks for the microphone and speech recognition: allow both, as a
    /// person would. Nothing happens when they were already granted.
    private func allowPermissionPrompts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let alert = springboard.alerts.firstMatch
            guard alert.waitForExistence(timeout: 6) else { return }
            for label in ["Allow", "OK", "Allow While Using App"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                break
            }
        }
    }

    /// Generate, then wait until that answer is on screen and the status has moved on.
    private func generateAndWait(_ app: XCUIApplication, expectStatus: String) {
        pause(3.5)                                             // a new line of speech to answer
        app.buttons["Generate an answer"].tap()
        let status = element(app, "free-answers-status")
        let moved = expectation(for: NSPredicate(format: "label BEGINSWITH %@", expectStatus), evaluatedWith: status)
        wait(for: [moved], timeout: 30)
    }

    func testTwoFreeAnswersThenThePaywallWithTheSessionIntact() throws {
        let app = launch(reset: true)
        XCTAssertTrue(app.waitForNeverblankHome(), "Neverblank did not open on its home screen")
        allowPermissionPrompts()
        XCTAssertTrue(element(app, "free-answers-disclosure").waitForExistence(timeout: 20), "the 2 free answers are not disclosed")
        XCTAssertTrue(element(app, "free-answers-disclosure").label.contains("2 free AI answers"))
        save(app, "free-1-home")

        let start = app.buttons["Start interview, LIVE mode"]
        XCTAssertTrue(start.waitForExistence(timeout: 30))
        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: start)
        wait(for: [enabled], timeout: 30)
        start.tap()
        let agree = app.buttons["ai-consent-agree"]
        XCTAssertTrue(agree.waitForExistence(timeout: 10), "no AI consent before the first Live interview")
        XCTAssertTrue(app.staticTexts["2 free AI answers"].exists)
        agree.tap()

        XCTAssertTrue(app.buttons["Generate an answer"].waitForExistence(timeout: 15), "the Live interview never opened")
        XCTAssertTrue(element(app, "free-answers-status").waitForExistence(timeout: 20))
        XCTAssertEqual(status(app), "2 free answers remaining")
        save(app, "free-2-two-remaining")

        generateAndWait(app, expectStatus: "1 free answer remaining")
        save(app, "free-3-one-remaining")

        generateAndWait(app, expectStatus: "Free answers used")
        let headline = app.staticTexts["Never interview alone again."]
        XCTAssertFalse(headline.exists, "the second answer was covered by the paywall")
        XCTAssertTrue(app.buttons["unlock-pro"].exists, "no inline Unlock Pro after the second answer")
        save(app, "free-4-used-inline-unlock")

        // The third Generate asks for Pro before anything is sent, and keeps the request.
        pause(3.5)
        app.buttons["Generate an answer"].tap()
        XCTAssertTrue(headline.waitForExistence(timeout: 10), "the third Generate did not open the paywall")
        save(app, "free-5-paywall-on-third")
        app.buttons["paywall-close"].tap()
        let kept = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Neverblank Pro is needed")).firstMatch
        XCTAssertTrue(kept.waitForExistence(timeout: 10), "the held request was not kept for Retry")

        // Settings › Subscription is reachable mid-interview.
        app.buttons["Interview settings"].tap()
        XCTAssertTrue(app.buttons["view-plans"].waitForExistence(timeout: 10))
        app.buttons["Done"].tap()
        save(app, "free-6-kept-for-retry")

        // A relaunch keeps the used allowance.
        app.terminate()
        let again = launch(reset: false)
        XCTAssertTrue(again.waitForNeverblankHome())
        let disclosure = element(again, "free-answers-disclosure")
        XCTAssertTrue(disclosure.waitForExistence(timeout: 20))
        let used = expectation(for: NSPredicate(format: "label CONTAINS %@", "free AI answers are used"), evaluatedWith: disclosure)
        wait(for: [used], timeout: 20)
        save(again, "free-7-after-relaunch")
    }
}
