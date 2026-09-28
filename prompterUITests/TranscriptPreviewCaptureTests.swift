import XCTest

/// The collapsed Live transcript while speech streams: screenshots every few seconds for 25 seconds,
/// to check it stays exactly three lines tall with no 4/5-line flash, then expanded and collapsed.
/// Uses the scripted demo interview (Debug builds with -NeverblankDeveloperTools).
@MainActor
final class TranscriptPreviewCaptureTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = true }

    private func save(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCollapsedTranscriptWhileSpeechStreams() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestsQuietMotion", "-NeverblankDeveloperTools"]
        app.launch()
        XCTAssertTrue(app.waitForNeverblankHome())
        let demo = app.buttons["Start demo, DEMO mode"]
        app.scrollTo(demo)
        XCTAssertTrue(demo.waitForExistence(timeout: 10))
        demo.tap()
        let preview = app.descendants(matching: .any)["transcript-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 15), "no collapsed transcript")

        var heights: [CGFloat] = []
        for tick in 0..<5 {
            sleep(5)
            heights.append(preview.frame.height)
            save(app, "collapsed-\(tick * 5 + 5)s")
        }
        XCTAssertEqual(Set(heights).count, 1, "the collapsed preview changed height while speech streamed: \(heights)")

        let toggle = app.buttons["Expand live transcript"]
        toggle.tap()
        sleep(2)
        save(app, "expanded")
        app.buttons["Collapse live transcript"].tap()
        sleep(1)
        save(app, "collapsed-again")
        XCTAssertEqual(preview.frame.height, heights.first ?? 0, "collapsing returns to the same three-line height")
    }
}
