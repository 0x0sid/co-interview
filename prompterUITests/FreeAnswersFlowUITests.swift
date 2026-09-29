import XCTest

/// The first-run funnel on a real (local) backend: a fresh install gets its credential, consents, uses
/// its **3 free interview answers**, and the fourth Generate opens the paywall **once** by itself — with
/// the session intact and nothing sent. After that, blocked questions meet the quiet inline lock
/// ("Upgrade to continue") and only an explicit Upgrade opens the paywall; answered pages keep working.
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

    func testThreeFreeAnswersThenThePaywallWithTheSessionIntact() throws {
        let app = launch(reset: true)
        XCTAssertTrue(app.waitForNeverblankHome(), "Neverblank did not open on its home screen")
        allowPermissionPrompts()
        XCTAssertTrue(element(app, "free-answers-disclosure").waitForExistence(timeout: 20), "the 3 free answers are not disclosed")
        XCTAssertTrue(element(app, "free-answers-disclosure").label.contains("3 free interview answers"))
        save(app, "free-1-home")

        let start = app.buttons["start-interview"]
        XCTAssertTrue(start.waitForExistence(timeout: 30))
        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: start)
        wait(for: [enabled], timeout: 30)
        start.tap()
        let agree = app.buttons["ai-consent-agree"]
        XCTAssertTrue(agree.waitForExistence(timeout: 10), "no AI consent before the first Live interview")
        XCTAssertTrue(app.staticTexts["3 free interview answers"].exists)
        agree.tap()

        XCTAssertTrue(app.buttons["Generate an answer"].waitForExistence(timeout: 15), "the Live interview never opened")
        XCTAssertTrue(element(app, "free-answers-status").waitForExistence(timeout: 20))
        XCTAssertEqual(status(app), "3 free interview answers included.")
        save(app, "free-2-three-included")

        generateAndWait(app, expectStatus: "2 free interview answers remaining")
        generateAndWait(app, expectStatus: "1 free interview answer remaining")
        save(app, "free-3-one-remaining")

        // A. The third new answer succeeds and uses the last free answer.
        generateAndWait(app, expectStatus: "3 free answers used")
        let headline = app.staticTexts["Never interview alone again."]
        XCTAssertFalse(headline.exists, "the third answer was covered by the paywall")
        XCTAssertEqual(status(app), "3 free answers used. The transcript keeps going.")
        XCTAssertEqual(element(app, "upgrade-inline").label, "Upgrade", "no inline Upgrade after the third answer")
        XCTAssertTrue(pageCounter(app, "3/3").exists)
        save(app, "free-4-used-inline-upgrade")

        // B. The fourth new question opens the paywall by itself — once, before anything is sent.
        pause(3.5)
        app.buttons["Generate an answer"].tap()
        XCTAssertTrue(headline.waitForExistence(timeout: 10), "the fourth Generate did not open the paywall")
        save(app, "free-5-paywall-on-fourth")

        // C. Closing it returns to the same interview: no empty page, the transcript still there.
        app.buttons["paywall-close"].tap()
        XCTAssertTrue(headline.waitForNonExistence(timeout: 10))
        XCTAssertTrue(pageCounter(app, "3/3").exists, "an empty page was created for the blocked question")
        XCTAssertFalse(pageCounter(app, "/4").exists)
        XCTAssertTrue(app.buttons["Generate an answer"].exists, "not back in the interview")

        // D. More new questions: no modal, no page, the quiet lock says Upgrade to continue.
        for attempt in 1...3 {
            pause(3.5)
            app.buttons["Generate an answer"].tap()
            XCTAssertFalse(headline.waitForExistence(timeout: 4), "attempt \(attempt) reopened the paywall by itself")
        }
        XCTAssertFalse(pageCounter(app, "/4").exists, "a blocked question made a page")
        XCTAssertEqual(status(app), "3 free answers used. The transcript keeps going.")
        XCTAssertEqual(element(app, "upgrade-inline").label, "Upgrade to continue")
        save(app, "free-6-quiet-lock")

        // E. Left alone for several minutes: nothing opens by itself.
        pause(200)
        XCTAssertFalse(headline.exists, "the paywall reappeared while idle")
        save(app, "free-7-after-idle")

        // F–G. Upgrade is explicit intent: it opens the paywall, every time it is tapped.
        for round in 1...2 {
            element(app, "upgrade-inline").tap()
            XCTAssertTrue(headline.waitForExistence(timeout: 10), "Upgrade (\(round)) did not open the paywall")
            app.buttons["paywall-close"].tap()
            XCTAssertTrue(headline.waitForNonExistence(timeout: 10))
        }

        // H. Regenerate an answered page: allowed, no paywall.
        app.buttons["More actions"].tap()
        let regenerate = app.buttons["Regenerate answer"]
        XCTAssertTrue(regenerate.waitForExistence(timeout: 10))
        regenerate.tap()
        let version = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'v2 ·'")).firstMatch
        XCTAssertTrue(version.waitForExistence(timeout: 30), "Regenerate on a credited page did not answer")
        XCTAssertFalse(headline.exists, "Regenerate opened the paywall")

        // I. A follow-up on the answered page: allowed, no paywall.
        let actions = element(app, "follow-up-actions")
        XCTAssertTrue(actions.waitForExistence(timeout: 15))
        actions.buttons.firstMatch.tap()
        XCTAssertTrue(pageCounter(app, "4/4").waitForExistence(timeout: 30), "the follow-up did not open its page")
        XCTAssertTrue(element(app, "answer-complete").waitForExistence(timeout: 30), "the follow-up was not answered")
        XCTAssertFalse(headline.exists, "a follow-up opened the paywall")
        XCTAssertEqual(status(app), "3 free answers used. The transcript keeps going.", "credited pages used no allowance")
        save(app, "free-8-regenerate-and-follow-up")

        // Settings › Subscription is reachable mid-interview.
        app.buttons["Interview settings"].tap()
        XCTAssertTrue(app.buttons["view-plans"].waitForExistence(timeout: 10))
        app.buttons["Done"].tap()

        // J. Relaunch and a new meeting: the allowance stays used, the paywall does not open by itself.
        app.terminate()
        let again = launch(reset: false)
        XCTAssertTrue(again.waitForNeverblankHome())
        let disclosure = element(again, "free-answers-disclosure")
        XCTAssertTrue(disclosure.waitForExistence(timeout: 20))
        let used = expectation(for: NSPredicate(format: "label CONTAINS %@", "free AI answers are used"), evaluatedWith: disclosure)
        wait(for: [used], timeout: 20)
        let restart = again.buttons["start-interview"]
        XCTAssertTrue(restart.waitForExistence(timeout: 30))
        again.scrollTo(restart)
        restart.tap()
        let consent = again.buttons["ai-consent-agree"]
        if consent.waitForExistence(timeout: 3) { consent.tap() }
        XCTAssertTrue(again.buttons["Generate an answer"].waitForExistence(timeout: 20), "the new meeting never opened")
        pause(4)
        again.buttons["Generate an answer"].tap()
        let againHeadline = again.staticTexts["Never interview alone again."]
        XCTAssertFalse(againHeadline.waitForExistence(timeout: 5), "the new meeting reopened the paywall by itself")
        XCTAssertEqual(element(again, "upgrade-inline").label, "Upgrade to continue")
        save(again, "free-9-new-meeting-quiet-lock")
    }

    /// The question bar's "n/N" (its accessibility label is "Question n/N. …").
    private func pageCounter(_ app: XCUIApplication, _ fragment: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Question ' AND label CONTAINS %@", fragment)).firstMatch
    }
}
