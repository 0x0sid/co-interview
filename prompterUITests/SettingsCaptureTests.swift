import XCTest

/// Screenshots of Settings (Neverblank Pro card, Interview Language and its speech-model card) in light
/// and dark appearance, for review. Captures only; asserts that the two setup cards are present.
@MainActor
final class SettingsCaptureTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = true }

    private func save(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCaptureSettingsInLightAndDark() throws {
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments += ["-UITestsQuietMotion", "-UITestsAppearance", appearance]
            app.launch()
            XCTAssertTrue(app.waitForNeverblankHome())
            save(app, "home-\(appearance)")
            // The home screen re-lays out while its launch checks finish; tap once the gear is
            // hittable, and again if the sheet did not open.
            let gear = app.buttons["home-settings"]
            for _ in 0..<3 where !app.buttons["interview-language"].exists {
                _ = gear.waitForExistence(timeout: 5)
                if gear.isHittable { gear.tap() }
                _ = app.buttons["interview-language"].waitForExistence(timeout: 5)
            }
            sleep(3)                                             // let the speech-model check settle
            save(app, "settings-\(appearance)")
            XCTAssertTrue(app.descendants(matching: .any)["subscription-title"].exists, "no Neverblank Pro card")
            XCTAssertTrue(app.buttons["interview-language"].exists)
            app.terminate()
        }
    }
}
