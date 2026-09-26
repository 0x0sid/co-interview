import XCTest

/// The paywall with **real** offerings from the RevenueCat Test Store (the Debug build's `test_` key).
///
/// Opt-in: `TEST_RUNNER_NEVERBLANK_TEST_STORE=1`. It needs network access and the Neverblank project's
/// Test Store configuration, and proves only that plans and prices load — never that an Apple
/// purchase works.
@MainActor
final class PaywallPlansUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["NEVERBLANK_TEST_STORE"] == "1" else {
            throw XCTSkip("set NEVERBLANK_TEST_STORE=1 to load the Test Store offering")
        }
    }

    func testThePaywallShowsTheStorePlans() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestsQuietMotion"]
        app.launch()
        XCTAssertTrue(app.waitForNeverblankHome(), "Neverblank did not open on its home screen")
        let viewPlans = app.buttons["view-plans"]
        XCTAssertTrue(viewPlans.waitForExistence(timeout: 10))
        app.scrollTo(viewPlans)
        viewPlans.tap()
        XCTAssertTrue(app.staticTexts["Never interview alone again."].waitForExistence(timeout: 10))

        let rows = ["weekly", "monthly", "yearly", "lifetime"].map { app.buttons["plan-\($0)"] }
        XCTAssertTrue(rows.contains { $0.waitForExistence(timeout: 20) }, "no plan loaded from the store")
        let loaded = ["weekly", "monthly", "yearly", "lifetime"].filter { app.buttons["plan-\($0)"].exists }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "paywall-test-store-plans: \(loaded.joined(separator: ","))"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("PLANS LOADED: \(loaded)")
        print("PLAN LABELS: \(loaded.map { app.buttons["plan-\($0)"].label })")
        XCTAssertTrue(app.buttons["paywall-continue"].exists, "plans loaded but no Continue")
    }
}
