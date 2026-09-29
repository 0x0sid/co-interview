import Foundation
import SwiftData
import Testing
@testable import prompter

/// Settings › Answer text size: the drag moves only the Settings draft and its preview; the stored
/// preference is written once, on release. Nothing about a running interview is touched by the drag.
@MainActor
struct AnswerTextSizeTests {
    /// What Settings does with a value the editor hands back: the one write, counted.
    final class Store {
        var value: Double
        private(set) var writes = 0
        init(_ value: Double) { self.value = value }
        func persist(_ newValue: Double?) {
            guard let newValue else { return }
            value = newValue
            writes += 1
        }
    }

    @Test
    func aDragUpdatesTheDisplayedValueAndWritesNothingUntilRelease() {
        let store = Store(1.0)
        var editor = AnswerTextSizeEditor(persisted: store.value)
        store.persist(editor.setEditing(true))
        // A slider at touch rate: many calls, most repeating the same snapped value.
        for tick in 0..<240 {
            let value = 1.0 + Double(tick % 40) / 100                               // 1.00 … 1.39
            store.persist(editor.update(value))
        }
        store.persist(editor.update(1.3))
        #expect(store.writes == 0, "nothing stored during the drag")
        #expect(editor.displayed == 1.3 && editor.percent == 130, "the percentage and preview follow at once")
        store.persist(editor.setEditing(false))
        #expect(store.writes == 1 && store.value == 1.3, "one write, the final value, on release")
    }

    @Test
    func releasingOnTheOriginalValueWritesNothing() {
        let store = Store(1.2)
        var editor = AnswerTextSizeEditor(persisted: store.value)
        store.persist(editor.setEditing(true))
        store.persist(editor.update(1.5))
        store.persist(editor.update(1.2))
        store.persist(editor.setEditing(false))
        #expect(store.writes == 0)
    }

    /// VoiceOver's increment/decrement is not a drag: each step is stored at once.
    @Test
    func anAccessibilityAdjustmentIsStoredImmediately() {
        let store = Store(1.0)
        var editor = AnswerTextSizeEditor(persisted: store.value)
        store.persist(editor.update(1.1))
        #expect(store.writes == 1 && store.value == 1.1)
    }

    @Test
    func valuesSnapToTenPercentStepsWithinTheRange() {
        var editor = AnswerTextSizeEditor(persisted: 0.5)
        #expect(editor.displayed == 0.8, "an out-of-range stored value is clamped")
        _ = editor.setEditing(true)
        _ = editor.update(1.234)
        #expect(editor.displayed == 1.2)
        _ = editor.update(9)
        #expect(editor.displayed == 1.6 && editor.percent == 160)
    }

    @Test
    func aStoredChangeElsewhereIsFollowedButNeverMidDrag() {
        var editor = AnswerTextSizeEditor(persisted: 1.0)
        editor.syncPersisted(1.4)                                                   // e.g. reopening Settings
        #expect(editor.displayed == 1.4)
        _ = editor.setEditing(true)
        _ = editor.update(0.9)
        editor.syncPersisted(1.4)
        #expect(editor.displayed == 0.9, "the finger wins while dragging")
    }

    // MARK: Persistence: reopen and relaunch

    @Test
    func theCommittedValueSurvivesReopeningSettingsAndARelaunch() throws {
        let url = SessionTestSupport.temporaryDirectory().appending(path: "store.sqlite")
        do {
            let context = ModelContext(try SessionTestSupport.container(at: url))
            let settings = AppSettings.fetchOrCreate(in: context)
            var editor = AnswerTextSizeEditor(persisted: settings.fontScale)
            _ = editor.setEditing(true)
            _ = editor.update(1.4)
            if let commit = editor.setEditing(false) {
                settings.fontScale = commit
                try context.save()
            }
            // Settings closed and opened again, same process: a fresh editor reads the stored value.
            let reopened = AnswerTextSizeEditor(persisted: AppSettings.fetchOrCreate(in: context).fontScale)
            #expect(reopened.displayed == 1.4)
        }
        // A relaunch: a new container over the same file.
        let relaunched = ModelContext(try SessionTestSupport.container(at: url))
        #expect(AppSettings.fetchOrCreate(in: relaunched).fontScale == 1.4)
    }

    // MARK: A running interview is untouched

    /// The text size is only an environment value for answer views: committing it leaves the
    /// interview's pages, the selected page, the speech-following alignment and the requests as they
    /// were — nothing is regenerated, re-parsed into new blocks, or reset.
    @Test
    func committingTheSizeLeavesTheRunningInterviewAsItWas() throws {
        let feed = ManualGenerationTests.RecordingFeed()
        var question = InterviewQuestion(text: "Why Kafka?")
        question.answers = [InterviewAnswer(version: 1, blocks: AnswerBlock.parsed(from: "Kafka keeps an ==ordered log==.\n- Consumers replay."),
                                            isComplete: true)]
        var restored = RestoredInterview()
        restored.questions = [question]
        let model = InterviewScreenModel(mode: .live, feed: feed, restored: restored)
        let page = try #require(model.questions.first)
        let alignment = try #require(model.alignment(for: page))
        let pagesBefore = model.questions
        let indexBefore = model.currentIndex

        // Settings, meanwhile, drags and commits.
        let context = ModelContext(try SessionTestSupport.container())
        let settings = AppSettings.fetchOrCreate(in: context)
        var editor = AnswerTextSizeEditor(persisted: settings.fontScale)
        _ = editor.setEditing(true)
        for value in stride(from: 1.0, through: 1.5, by: 0.01) { _ = editor.update(value) }
        if let commit = editor.setEditing(false) { settings.fontScale = commit; try context.save() }

        #expect(model.questions == pagesBefore, "same pages, same answers")
        #expect(model.currentIndex == indexBefore, "the reader stays on the same page")
        #expect(model.alignment(for: page) === alignment, "speech-following keeps its alignment and progress")
        #expect(feed.discussionRequests.isEmpty, "nothing regenerated")
    }
}
