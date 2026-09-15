import Testing
import SwiftUI
@testable import prompter

/// M5.1-D: auto-detected direction per dominant language, manual override always wins.
struct TextDirectionDetectorTests {
    @Test
    func detectsArabicAsRightToLeft() {
        let arabic = "مرحبا بكم في هذا البرنامج التجريبي الذي يتيح لكم قراءة النص بصوت عالٍ"
        #expect(TextDirectionDetector.detectedDirection(for: arabic) == .rightToLeft)
    }

    @Test
    func detectsEnglishAsLeftToRight() {
        let english = "Welcome to this demonstration script that you can read aloud for testing."
        #expect(TextDirectionDetector.detectedDirection(for: english) == .leftToRight)
    }

    @Test
    func manualOverrideWinsRegardlessOfContent() {
        let arabic = "مرحبا بكم في هذا البرنامج التجريبي"
        #expect(TextDirectionDetector.resolvedDirection(for: arabic, override: .leftToRight) == .leftToRight)

        let english = "Welcome to this demonstration script."
        #expect(TextDirectionDetector.resolvedDirection(for: english, override: .rightToLeft) == .rightToLeft)
    }

    @Test
    func autoOverrideDefersToDetection() {
        let arabic = "مرحبا بكم في هذا البرنامج التجريبي"
        #expect(TextDirectionDetector.resolvedDirection(for: arabic, override: .auto) == .rightToLeft)
    }
}
