import XCTest

extension XCUIApplication {
    /// "Start interview" or "Start interview (listening only)" — present only on Neverblank's home.
    var startInterviewButton: XCUIElement {
        buttons.matching(NSPredicate(format: "label BEGINSWITH 'Start interview'")).firstMatch
    }

    /// Neverblank opens directly on its home screen, with no entry step. True once it is showing.
    @discardableResult
    func waitForNeverblankHome(timeout: TimeInterval = 20) -> Bool {
        startInterviewButton.waitForExistence(timeout: timeout)
    }

    /// Scrolls the home screen until `element` can be tapped.
    func scrollTo(_ element: XCUIElement, maxSwipes: Int = 8) {
        var swipes = 0
        while !element.isHittable && swipes < maxSwipes {
            swipeUp()
            swipes += 1
        }
    }
}
