import XCTest

/// Screenshots of Home and Settings for design review — run on a small iPhone (SE) and a regular one.
/// States the simulator cannot reach by itself (an expired subscription, a missing speech model) are
/// forced with DEBUG-only launch arguments. Captures, plus a few structural checks.
@MainActor
final class SettingsCaptureTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = true }

    private func save(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launch(_ appearance: String, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestsQuietMotion", "-UITestsAppearance", appearance, "-UITestsSeedHistory"] + extra
        app.launch()
        // A fresh simulator asks for the microphone and speech recognition; answer as a person would.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<2 {
            let alert = springboard.alerts.firstMatch
            guard alert.waitForExistence(timeout: 3) else { break }
            for label in ["Allow", "OK"] where alert.buttons[label].exists { alert.buttons[label].tap(); break }
        }
        XCTAssertTrue(app.waitForNeverblankHome())
        return app
    }

    private func openSettings(_ app: XCUIApplication) {
        // The home screen re-lays out while its launch checks finish; tap once the gear is
        // hittable, and again if the sheet did not open.
        let gear = app.buttons["home-settings"]
        for _ in 0..<3 where !app.buttons["interview-language"].exists {
            _ = gear.waitForExistence(timeout: 5)
            if gear.isHittable { gear.tap() }
            _ = app.buttons["interview-language"].waitForExistence(timeout: 5)
        }
        sleep(2)                                                 // let the speech-model check settle
    }

    /// One pass: Home, then Settings (top and scrolled), in one appearance and forced state.
    private func capture(_ appearance: String, _ label: String, _ extra: [String] = []) {
        let app = launch(appearance, extra)
        sleep(1)
        save(app, "home-\(label)-\(appearance)")
        openSettings(app)
        save(app, "settings-\(label)-\(appearance)")
        XCTAssertTrue(app.descendants(matching: .any)["subscription-title"].exists, "no Neverblank Pro card")
        XCTAssertTrue(app.buttons["interview-language"].exists)
        app.swipeUp()
        sleep(1)
        save(app, "settings-\(label)-\(appearance)-lower")
        app.terminate()
    }

    func testCaptureSettingsInLightAndDark() throws {
        for appearance in ["light", "dark"] { capture(appearance, "default") }
    }

    /// Small-phone check of the subscription card in each state, with a long language name.
    func testCaptureSubscriptionStatesWithALongLanguageName() throws {
        capture("light", "free-zhTW-missing", ["-UITestsSubscriptionState", "free", "-UITestsSpeechModel", "needsDownload",
                                               "-UITestsInterviewLanguage", "zh-TW"])
        capture("dark", "expired-es", ["-UITestsSubscriptionState", "expired", "-UITestsSpeechModel", "installed",
                                       "-UITestsInterviewLanguage", "es-CL"])
        capture("light", "pro-fr", ["-UITestsSubscriptionState", "pro", "-UITestsSpeechModel", "installed",
                                    "-UITestsInterviewLanguage", "fr-FR"])
    }

    /// Each plan state of the Pro card, with dates in a long locale format, on whatever phone runs
    /// it (the SE is the one that matters). Every line of the card must stay inside the screen.
    func testCaptureEachPlanStateWithLocalizedDates() throws {
        let states: [(String, String)] = [("pro-weekly", "en_US"), ("pro", "fr_FR"), ("pro-yearly", "de_DE"),
                                          ("cancelled", "fr_FR"), ("grace", "de_DE"), ("expired", "en_GB"),
                                          ("expired-unknown", "zh_Hant_TW")]
        for (state, locale) in states {
            let app = launch("light", ["-UITestsSubscriptionState", state, "-UITestsSpeechModel", "installed",
                                       "-AppleLocale", locale])
            openSettings(app)
            save(app, "plan-\(state)-\(locale)")
            XCTAssertTrue(app.descendants(matching: .any)["subscription-title"].exists, "\(state): no Neverblank Pro card")
            for id in ["subscription-plan", "subscription-renewal", "subscription-note"] {
                let element = app.descendants(matching: .any)[id]
                guard element.exists else { continue }
                XCTAssertLessThanOrEqual(element.frame.maxX, app.frame.maxX - 8, "\(state) \(locale): \(id) runs off the card")
                XCTAssertGreaterThan(element.frame.height, 0)
            }
            app.terminate()
        }
    }

    func testCaptureExpiredSubscriptionAndMissingSpeechModel() throws {
        capture("light", "expired-missing", ["-UITestsSubscriptionState", "expired", "-UITestsSpeechModel", "needsDownload"])
        capture("dark", "pro-installed", ["-UITestsSubscriptionState", "pro", "-UITestsSpeechModel", "installed"])
    }
}
