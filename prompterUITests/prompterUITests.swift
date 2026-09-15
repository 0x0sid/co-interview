//
//  prompterUITests.swift
//  prompterUITests
//
//  Created by Sidou on 09/08/2026.
//

import XCTest

final class prompterUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // XCUIAutomation Documentation
        // https://developer.apple.com/documentation/xcuiautomation
    }

    /// Diagnostic-only: captures the prompt screen's static initial render via the debug path
    /// (real mic, no speech in Simulator, so the cursor stays at token 0 — this is purely to look
    /// at layout/background/text color, not matcher behavior) — for chasing the "white square
    /// covering ~30% of the bottom" report visually rather than by guessing from code.
    @MainActor
    func testCaptureBarePromptScreen() throws {
        let app = XCUIApplication()
        app.launch()

        func capture(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        XCTAssertTrue(app.images["debugMenuButton"].waitForExistence(timeout: 10))
        app.images["debugMenuButton"].tap()
        let promptDebugEntry = app.staticTexts["Debug: Prompt Screen (arbitrary text)"]
        XCTAssertTrue(promptDebugEntry.waitForExistence(timeout: 5))
        promptDebugEntry.tap()
        XCTAssertTrue(app.buttons["Start"].waitForExistence(timeout: 5))
        app.buttons["Start"].tap()
        sleep(3)
        capture("PromptScreen-initial")
        sleep(4) // past the 3s auto-hide, bottom bar should be gone
        capture("PromptScreen-controls-hidden")
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

}
