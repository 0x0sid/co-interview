import Foundation

/// Debug-only content for the matcher replay screen (§10.5). Deliberately separate from the
/// ScriptWatchTests fixture suite (which needs `@testable` access and lives in the test target)
/// — this is a small, self-contained demo the shipped Debug build can play back with no test
/// target involved, showing the flagship moment: a skipped paragraph the matcher recovers from,
/// then an ad-lib the cursor holds through.
struct ReplayFixture {
    struct Event {
        let tokens: [Token]
        /// Seconds from the start of playback.
        let elapsed: TimeInterval
    }

    let title: String
    let scriptText: String
    let events: [Event]
}

enum DemoReplayFixtures {
    static let paragraphSkipAndAdLib: ReplayFixture = build()

    private static let script = """
    Today we are going to show you something we have been building for the last year. It is a \
    small device that fits in your pocket, and it is going to change the way you think about \
    your morning routine. We built it because we were tired of juggling five different apps \
    just to get out the door on time.

    The idea started on a napkin during a rainy afternoon in October. Two of our engineers were \
    stuck at the airport, and they realized that every travel app they owned was fighting for \
    their attention instead of working together. So they sketched a simpler version, one screen, \
    one button, and no notifications unless something actually mattered.

    Over the following months the team tested more than forty prototypes. Some were too heavy, \
    some drained the battery in a single afternoon, and one memorable version could not survive \
    a light rain shower. Each failure taught us something we could not have learned any other \
    way, and slowly the design became lighter, quieter, and far more durable.

    What you are looking at today is the result of that work. It ships next month, it is priced \
    fairly, and every part of it was designed to disappear into your daily life rather than \
    demand your attention. We think that is what good technology should do, and we cannot wait \
    for you to try it.
    """

    private static let secondsPerWord: TimeInterval = 0.4

    private static func build() -> ReplayFixture {
        let index = ScriptIndex.build(from: script)
        let tokens = index.tokenTexts
        let paragraphs = index.paragraphTokenRanges

        var events: [ReplayFixture.Event] = []
        var time: TimeInterval = 0

        func speak(_ range: Range<Int>, batchSize: Int = 4) {
            var i = range.lowerBound
            while i < range.upperBound {
                let end = min(i + batchSize, range.upperBound)
                var batch: [Token] = []
                for idx in i..<end {
                    time += secondsPerWord
                    batch.append(Token(tokens[idx], at: time))
                }
                events.append(ReplayFixture.Event(tokens: batch, elapsed: time))
                i = end
            }
        }

        func adLib() {
            let words = "so yeah i think what i really want to say here is that this whole thing about the weather today has been absolutely wild if you ask me honestly"
                .split(separator: " ").map(String.init)
            var batch: [Token] = []
            for word in words {
                time += secondsPerWord
                batch.append(Token(word, at: time))
                if batch.count == 4 {
                    events.append(ReplayFixture.Event(tokens: batch, elapsed: time))
                    batch = []
                }
            }
            if !batch.isEmpty {
                events.append(ReplayFixture.Event(tokens: batch, elapsed: time))
            }
        }

        guard paragraphs.count >= 3 else {
            speak(0..<tokens.count)
            return ReplayFixture(title: "Paragraph skip + ad-lib", scriptText: script, events: events)
        }

        // Paragraph 0 clean, skip paragraph 1 entirely (recovery jump), ad-lib partway through
        // paragraph 2, then finish clean.
        speak(paragraphs[0])
        let resumeStart = paragraphs[2].lowerBound
        let adLibSplit = resumeStart + paragraphs[2].count / 3
        speak(resumeStart..<adLibSplit)
        adLib()
        speak(adLibSplit..<tokens.count)

        return ReplayFixture(title: "Paragraph skip + ad-lib", scriptText: script, events: events)
    }
}
