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
        let states: [(String, String)] = [("pro-weekly", "fr_FR"), ("cancelled", "en_US"), ("pro-yearly", "de_DE"),
                                          ("grace", "fr_FR"), ("billing-expired", "en_GB"), ("expired", "en_US"),
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

    /// Appearance chosen in Settings — the stored preference, not a forced launch argument — switched
    /// System → Light → Dark → Ultra → System, captured immediately after each tap and a moment later.
    func testAppearanceSwitchesUpdateSettingsAtOnce() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestsQuietMotion", "-UITestsSpeechModel", "installed", "-UITestsSubscriptionState", "pro"]
        app.launch()
        XCTAssertTrue(app.waitForNeverblankHome())
        openSettings(app)
        let picker = app.segmentedControls["appearance"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        for label in ["Light", "Dark", "Ultra", "System", "Dark", "Light", "Ultra", "Light"] {
            picker.buttons[label].tap()
            usleep(400_000)                                  // one animation, not a settle-and-hope wait
            let shot = XCUIScreen.main.screenshot()
            save(app, "appearance-\(label)")
            // The Settings sheet background (left margin, beside the cards): it must follow the choice on this tap.
            let brightness = Self.brightness(of: shot.image, atX: 0.02, y: 0.2)
            switch label {
            case "Light": XCTAssertGreaterThan(brightness, 0.75, "Light: the open Settings sheet did not turn light")
            case "Dark": XCTAssertLessThan(brightness, 0.3, "Dark: the open Settings sheet stayed light")
            case "Ultra": XCTAssertLessThan(brightness, 0.08, "Ultra: the open Settings sheet is not black")
            default: break
            }
        }
    }

    /// Mean brightness (0…1) of a small patch of the screenshot at a relative position.
    private static func brightness(of image: UIImage, atX x: CGFloat, y: CGFloat) -> CGFloat {
        guard let cg = image.cgImage else { return -1 }
        let px = Int(CGFloat(cg.width) * x), py = Int(CGFloat(cg.height) * y)
        let size = 6
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard let context = CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let patch = cg.cropping(to: CGRect(x: px, y: py, width: size, height: size)) else { return -1 }
        context.draw(patch, in: CGRect(x: 0, y: 0, width: size, height: size))
        var total: CGFloat = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            total += (CGFloat(pixels[i]) * 0.299 + CGFloat(pixels[i + 1]) * 0.587 + CGFloat(pixels[i + 2]) * 0.114) / 255
        }
        return total / CGFloat(size * size)
    }

    func testCaptureExpiredSubscriptionAndMissingSpeechModel() throws {
        capture("light", "expired-missing", ["-UITestsSubscriptionState", "expired", "-UITestsSpeechModel", "needsDownload"])
        capture("dark", "pro-installed", ["-UITestsSubscriptionState", "pro", "-UITestsSpeechModel", "installed"])
    }
}
