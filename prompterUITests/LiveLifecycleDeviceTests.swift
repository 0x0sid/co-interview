import XCTest

/// Enter and leave a real Live interview three times on a phone, so the app's `[Lifecycle]` console
/// lines can show that each exit releases the microphone and each entry builds exactly one pipeline.
///
/// Opt-in, device only: run with `TEST_RUNNER_LIFECYCLE_DEVICE=1` while the app is already running
/// with its console attached (`devicectl device process launch --console`). The test **attaches** to
/// that process (`activate()`), it does not relaunch it, so the console keeps streaming. It touches no
/// data: it opens a new interview and closes it.
@MainActor
final class LiveLifecycleDeviceTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["LIFECYCLE_DEVICE"] == "1" else {
            throw XCTSkip("set LIFECYCLE_DEVICE=1 to run the on-device lifecycle pass")
        }
    }

    private func pause(_ seconds: TimeInterval) {
        let done = expectation(description: "pause")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: seconds + 3)
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testEnterAndLeaveThreeTimes() throws {
        let app = XCUIApplication()
        app.activate()
        XCTAssertTrue(app.waitForNeverblankHome(timeout: 30), "Neverblank's home is not showing")

        for round in 1...3 {
            let start = app.buttons["start-interview"]
            app.scrollTo(start)
            start.tap()
            let agree = app.buttons["ai-consent-agree"]
            if agree.waitForExistence(timeout: 3) { agree.tap() }
            XCTAssertTrue(app.buttons["Close interview"].waitForExistence(timeout: 20), "round \(round): the interview did not open")
            pause(8)                                   // listening
            snapshot("round \(round) listening")
            app.buttons["Close interview"].tap()
            XCTAssertTrue(app.waitForNeverblankHome(timeout: 15), "round \(round): did not return home")
            pause(2)
            snapshot("round \(round) after exit")
            pause(6)                                   // idle on the home screen
        }
        pause(15)                                      // nothing may happen after the last exit
        snapshot("final idle")
    }
}
