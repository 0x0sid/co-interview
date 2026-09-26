import XCTest

/// The first-run funnel on a real (local) backend: a fresh install gets its credential, consents,
/// listens for the 30-second free preview, and meets the paywall — with the session intact.
///
/// Opt-in: start `backend/` locally with `COINTERVIEW_FAKE=1` and a temporary `ACCESS_DB_PATH`, then
/// run with `TEST_RUNNER_NEVERBLANK_ACCESS_URL=http://127.0.0.1:<port>`. The backend is fake (canned
/// answers), so nothing is billed; access control is the real code. Purchases are **not** exercised:
/// they need the Neverblank RevenueCat project and an Apple sandbox account.
@MainActor
final class FreePreviewFlowUITests: XCTestCase {
    private var backendURL = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let url = ProcessInfo.processInfo.environment["NEVERBLANK_ACCESS_URL"], !url.isEmpty else {
            throw XCTSkip("set NEVERBLANK_ACCESS_URL to a local backend to run the free-preview flow")
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

    func testThePreviewEndsInThePaywallAndTheSessionSurvives() throws {
        let lines = (1...14).map { "Question number \($0), how would you design a rate limiter?" }
        let app = XCUIApplication()
        app.launchArguments += [
            "-NeverblankResetAccess",
            "-CopilotInstallationAuth",
            "-CopilotBackendURL", backendURL,
            "-UITestsQuietMotion",
            "-LiveScriptedSpeech", lines.joined(separator: "||"),
            "-LiveScriptedSpeechInterval", "4",
        ]
        app.launch()

        let entry = app.buttons["Interview Copilot. Listens, suggests answers, and follows your voice as you read them."]
        XCTAssertTrue(entry.waitForExistence(timeout: 20))
        let startLive = app.buttons["Start live, LIVE mode"]
        for _ in 0..<3 where !startLive.exists {
            entry.tap()
            _ = startLive.waitForExistence(timeout: 10)
        }
        // The preview is disclosed before Live starts.
        XCTAssertTrue(element(app, "preview-disclosure").waitForExistence(timeout: 15), "the free preview is not disclosed")

        // Settings › Subscription is always reachable; with no plans loadable the paywall still
        // opens, says why, and offers Retry and Restore — never a hidden paywall or an invented price.
        let viewPlans = app.buttons["view-plans"]
        XCTAssertTrue(viewPlans.waitForExistence(timeout: 10), "no View plans on the start screen")
        if !viewPlans.isHittable { app.swipeUp() }
        viewPlans.tap()
        XCTAssertTrue(app.staticTexts["Never interview alone again."].waitForExistence(timeout: 10), "View plans did not open the paywall")
        XCTAssertTrue(element(app, "paywall-plans-unavailable").waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["paywall-retry"].exists, "no Retry when plans are unavailable")
        XCTAssertTrue(app.buttons["paywall-restore"].exists, "no Restore on the paywall")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '$'")).firstMatch.exists, "a price shown without the store")
        save(app, "access-0-plans-unavailable")
        app.buttons["paywall-close"].tap()
        XCTAssertTrue(app.staticTexts["Never interview alone again."].waitForNonExistence(timeout: 10))
        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: startLive)
        wait(for: [enabled], timeout: 30)
        save(app, "access-1-start-screen")
        if !startLive.isHittable { app.swipeUp() }
        startLive.tap()

        // A fresh install is asked for AI consent first.
        let agree = app.buttons["ai-consent-agree"]
        XCTAssertTrue(agree.waitForExistence(timeout: 10), "no AI consent before the first Live interview")
        save(app, "access-2-consent")
        agree.tap()

        XCTAssertTrue(app.buttons["Generate an answer"].waitForExistence(timeout: 15), "the Live interview never opened")
        let status = element(app, "preview-status")
        XCTAssertTrue(status.waitForExistence(timeout: 20))
        XCTAssertTrue(status.label.hasPrefix("Free preview ·"), "status was “\(status.label)”")
        save(app, "access-3-preview-running")

        // About thirty seconds of listening later, the paywall — once.
        let headline = app.staticTexts["Never interview alone again."]
        XCTAssertTrue(headline.waitForExistence(timeout: 60), "the paywall never appeared at the end of the preview")
        XCTAssertTrue(app.staticTexts["Real-time answers when the questions start."].exists)
        // No RevenueCat key in this run, so no plans load: the page says so and offers no Continue.
        XCTAssertTrue(app.buttons["paywall-restore"].exists)
        XCTAssertFalse(app.buttons["paywall-continue"].exists, "a purchase button without plans")
        save(app, "access-4-paywall-at-preview-end")
        app.buttons["paywall-close"].tap()
        XCTAssertTrue(headline.waitForNonExistence(timeout: 10))

        // Listening goes on; the session is intact; the status says what still works.
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.label.hasPrefix("Free preview ended"), "status was “\(status.label)”")
        save(app, "access-5-after-preview")

        // Interview settings › Subscription is reachable mid-interview too.
        app.buttons["Interview settings"].tap()
        XCTAssertTrue(app.buttons["view-plans"].waitForExistence(timeout: 10), "no Subscription in interview settings")
        save(app, "access-5b-settings-subscription")
        app.buttons["Done"].tap()

        // Generate now asks for Pro and keeps the request.
        let waitForMoreSpeech = expectation(description: "new speech")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { waitForMoreSpeech.fulfill() }
        wait(for: [waitForMoreSpeech], timeout: 8)
        app.buttons["Generate an answer"].tap()
        XCTAssertTrue(headline.waitForExistence(timeout: 10), "Generate without access did not offer Pro")
        XCTAssertTrue(app.staticTexts["Your answer is kept. It will be written as soon as you unlock Pro."].exists)
        save(app, "access-6-paywall-from-generate")
        app.buttons["paywall-close"].tap()
        let kept = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Neverblank Pro is needed")).firstMatch
        XCTAssertTrue(kept.waitForExistence(timeout: 10), "the held request was not kept on its page")
        save(app, "access-7-request-kept-for-retry")

        // The paywall did not come back by itself.
        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { settle.fulfill() }
        wait(for: [settle], timeout: 9)
        XCTAssertFalse(headline.exists, "the paywall reopened without being asked")
    }
}
