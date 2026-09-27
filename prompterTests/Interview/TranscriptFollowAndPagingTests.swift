import Foundation
import Testing
@testable import prompter

/// The expanded Live transcript follows the newest speech like a terminal, and answer pages share one
/// navigation state whether reached by arrows or by swiping.
@MainActor
struct TranscriptFollowTests {
    @Test
    func opensAtTheLatestAndFollowsNewSpeech() {
        var follow = TranscriptFollow()
        follow.jumpToLatest()                                   // opened
        #expect(follow.isFollowing)
        #expect(follow.shouldScrollForNewContent(), "new lines keep the view pinned")
        #expect(!follow.showsLatestButton)
    }

    @Test
    func scrollingUpStopsFollowingAndNewSpeechDoesNotPullTheReaderDown() {
        var follow = TranscriptFollow()
        follow.readerBeganScrolling()
        #expect(!follow.shouldScrollForNewContent(), "no jump while the reader's finger is down")
        follow.scrollSettled(atBottom: false)
        #expect(!follow.isFollowing)
        #expect(!follow.shouldScrollForNewContent(), "reading older text: new speech does not scroll")
        #expect(follow.showsLatestButton, "↓ Latest is offered")
    }

    @Test
    func tappingLatestReturnsToTheBottomAndFollows() {
        var follow = TranscriptFollow()
        follow.readerBeganScrolling()
        follow.scrollSettled(atBottom: false)
        follow.jumpToLatest()
        #expect(follow.isFollowing && follow.shouldScrollForNewContent() && !follow.showsLatestButton)
    }

    @Test
    func scrollingBackToTheBottomResumesFollowing() {
        var follow = TranscriptFollow()
        follow.readerBeganScrolling()
        follow.scrollSettled(atBottom: false)
        follow.readerBeganScrolling()
        follow.scrollSettled(atBottom: true)
        #expect(follow.isFollowing)
    }

    @Test
    func growthAloneNeverStopsFollowing() {
        var follow = TranscriptFollow()
        // Content grew, so the view is momentarily not at the bottom — but the reader did nothing.
        follow.scrollSettled(atBottom: false)
        #expect(follow.isFollowing, "only the reader's own scrolling changes following")
    }

    @Test
    func collapsingAndReopeningShowsTheNewest() {
        var follow = TranscriptFollow()
        follow.readerBeganScrolling()
        follow.scrollSettled(atBottom: false)
        follow.jumpToLatest()                                   // reopened
        #expect(follow.isFollowing)
    }
}

/// Arrows and swipes drive the same page identity; a page's own actions target that page.
@MainActor
struct AnswerPagingTests {
    typealias Support = ManualGenerationTests

    static func threePages() -> (InterviewScreenModel, ManualGenerationTests.RecordingFeed) {
        let (model, feed) = Support.make()
        for (n, text) in ["First?", "Second?", "Third?"].enumerated() {
            Support.speak(text, in: model)
            Support.tap(model, at: Double(n * 5))
            Support.completeActiveRequest(model, feed)
        }
        return (model, feed)
    }

    @Test
    func swipeAndArrowsShareOnePageState() {
        let (model, _) = Self.threePages()
        #expect(model.currentIndex == 2 && model.counterText == "3/3")
        model.select(index: 1)                                  // a swipe right (what the pager binding calls)
        #expect(model.counterText == "2/3")
        model.goToPrevious()                                    // the left arrow
        #expect(model.currentIndex == 0 && model.counterText == "1/3")
        model.goToNext()                                        // the right arrow
        model.select(index: 2)                                  // a swipe left
        #expect(model.currentIndex == 2 && model.counterText == "3/3")
        #expect(!model.canGoToNext)
    }

    @Test
    func swipingNeverGeneratesAnything() {
        let (model, feed) = Self.threePages()
        let sent = feed.discussionRequests.count
        model.select(index: 0); model.select(index: 1); model.select(index: 2)
        #expect(feed.discussionRequests.count == sent && feed.questionRequests.isEmpty)
    }

    @Test
    func regenerateAfterSwipingTargetsTheVisiblePage() throws {
        let (model, feed) = Self.threePages()
        model.select(index: 0)                                  // swiped back to the first answer
        model.regenerate()
        let request = try #require(feed.discussionRequests.last)
        #expect(request.questionID == model.questions[0].id)
        #expect(request.discussion.newInput == ["First?"], "the first page's own question, not the newest")
    }
}
