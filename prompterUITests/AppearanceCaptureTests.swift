import XCTest

/// **M5.10 screenshot capture** for the editor and Settings, which need navigation and therefore
/// cannot be reached with `simctl launch` alone. Writes PNGs to `/tmp` for the evidence folder.
final class AppearanceCaptureTests: XCTestCase {

    private func save(_ app: XCUIApplication, _ name: String) {
        let shot = app.screenshot()
        let url = URL(fileURLWithPath: "/tmp/m510-\(name).png")
        try? shot.pngRepresentation.write(to: url)
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCaptureEditorAndSettings() throws {
        let app = XCUIApplication()
        app.launch()

        // Library is the root. Open Settings via the gear.
        let gear = app.buttons["Settings"]
        if gear.waitForExistence(timeout: 10) {
            gear.tap()
            sleep(2)
            save(app, "settings")
            let done = app.buttons["Done"]
            if done.waitForExistence(timeout: 5) { done.tap() }
            sleep(1)
        }

        // New script -> the editor.
        let newScript = app.buttons["New script"]
        if newScript.waitForExistence(timeout: 10) {
            newScript.tap()
            sleep(3)
            save(app, "editor")
        }
    }
}
