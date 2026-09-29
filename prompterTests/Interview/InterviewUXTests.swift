import Foundation
import Testing
import UIKit
@testable import prompter

/// Adding typed context, the home screen's speech-model setup, and the appearance applied to windows.
struct InterviewUXTests {
    // MARK: Add context

    @Test
    func aBlankDraftAddsNothing() {
        #expect(ContextState.adding("", to: "") == nil)
        #expect(ContextState.adding("   \n  ", to: "Senior role") == nil, "whitespace only: the button stays disabled")
    }

    @Test
    func theFirstDraftBecomesTheContextTrimmed() {
        #expect(ContextState.adding("  I led the Kafka migration \n", to: "") == "I led the Kafka migration")
    }

    @Test
    func laterDraftsAreAddedOnTheirOwnLineKeepingEarlierContext() {
        let first = ContextState.adding("Senior backend role", to: "")!
        let second = ContextState.adding("I led the Kafka migration", to: first)
        #expect(second == "Senior backend role\nI led the Kafka migration")
    }

    /// A second tap, or the same text typed again, never duplicates it.
    @Test
    func theSameTextIsNeverAddedTwice() {
        let note = "Senior backend role\nI led the Kafka migration"
        #expect(ContextState.adding("I led the Kafka migration", to: note) == nil)
        #expect(ContextState.adding("  Senior backend role ", to: note) == nil)
    }

    /// Adding context sends nothing: it is only carried by the next Generate.
    @Test @MainActor
    func addedContextIsCarriedByTheNextGenerateAndGeneratesNothingByItself() throws {
        let (model, feed) = ManualGenerationTests.make()
        model.context.note = ContextState.adding("I led the Kafka migration", to: model.context.note)!
        model.syncSessionNote()
        #expect(feed.discussionRequests.isEmpty, "adding context does not generate an answer")
        ManualGenerationTests.speak("Why Kafka over RabbitMQ?", in: model)
        ManualGenerationTests.tap(model, at: 0)
        let request = try #require(feed.discussionRequests.last)
        #expect(request.discussion.note.contains("I led the Kafka migration"), "the next Generate carries the added context")
    }

    // MARK: Speech model setup on Home

    typealias Setup = SpeechSetupState

    @Test
    func noChosenLanguageAsksToChooseOne() {
        let state = Setup.make(hasChosenLanguage: false, needsModel: true, model: .needsDownload, languageName: "English")
        #expect(state == .chooseLanguage)
        #expect(state.headline == "Choose your interview language")
        #expect(state.helper != nil)
    }

    @Test
    func aChosenLanguageWithoutItsModelOffersTheDownload() {
        let state = Setup.make(hasChosenLanguage: true, needsModel: true, model: .needsDownload, languageName: "French")
        #expect(state == .download(languageName: "French"))
        #expect(state.headline == "Download the speech model")
        #expect(state.body == "Neverblank needs the French speech model before it can listen during a live interview.")
    }

    @Test
    func downloadingFailedUnsupportedAndReadyAreTheirOwnStates() {
        #expect(Setup.make(hasChosenLanguage: true, needsModel: true, model: .downloading(0.4), languageName: "French")
                == .downloading(fraction: 0.4, languageName: "French"))
        #expect(Setup.make(hasChosenLanguage: true, needsModel: true, model: .failed, languageName: "French")
                == .failed(languageName: "French"))
        #expect(Setup.make(hasChosenLanguage: false, needsModel: true, model: .unsupported, languageName: "Welsh")
                == .unsupported(languageName: "Welsh"))
        #expect(Setup.make(hasChosenLanguage: true, needsModel: false, model: .ready, languageName: "French") == .ready)
    }

    /// Never a fake "installed": while the status is still being read, a missing model is "checking".
    @Test
    func aModelStillBeingCheckedIsNotReportedReady() {
        #expect(Setup.make(hasChosenLanguage: true, needsModel: true, model: .checking, languageName: "French") == .checking)
        #expect(Setup.make(hasChosenLanguage: true, needsModel: false, model: .checking, languageName: "French") == .ready)
    }

    @Test
    func noLegacyBrandOrJargonInTheSetupCopy() {
        let states: [Setup] = [.chooseLanguage, .download(languageName: "English"), .downloading(fraction: 0.5, languageName: "English"),
                               .failed(languageName: "English"), .unsupported(languageName: "English")]
        for state in states {
            let text = [state.headline, state.body, state.helper ?? ""].joined(separator: " ")
            for word in ["Prompter", "Co-Interview", "asset", "locale"] {
                #expect(!text.contains(word), "\(state): \(word)")
            }
        }
    }

    // MARK: Appearance

    /// Applied to windows, so an open sheet changes with the choice.
    @Test
    func eachAppearanceMapsToOneWindowStyle() {
        #expect(AppearancePreference.system.interfaceStyle == .unspecified)
        #expect(AppearancePreference.light.interfaceStyle == .light)
        #expect(AppearancePreference.dark.interfaceStyle == .dark)
        #expect(AppearancePreference.ultraContrast.interfaceStyle == .dark)
        #expect(AppearancePreference.allCases.filter(\.isUltraContrast) == [.ultraContrast])
    }
}
