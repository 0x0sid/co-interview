import Foundation
@testable import prompter

/// Generates the six required noise scenarios (§16 M1) from a script's real tokens, so every
/// fixture has exact, programmatically-derived ground truth rather than hand-guessed positions.
enum FixtureBuilder {
    static func cleanRead(scriptName: String, scriptTokens: [String]) -> FixtureTranscript {
        let builder = TranscriptBuilder()
        builder.speak(TranscriptBuilder.clean(scriptTokens: scriptTokens, range: 0..<scriptTokens.count))
        return FixtureTranscript(scriptName: scriptName, scenario: "cleanRead", scriptTokens: scriptTokens, checkpoints: builder.checkpoints)
    }

    /// ~10% token corruption: homophone/character misrecognitions, dropped words, and
    /// "going to" -> "gonna" style contraction collapsing.
    static func misrecognition(scriptName: String, scriptTokens: [String]) -> FixtureTranscript {
        var units: [TranscriptBuilder.SpokenUnit] = []
        var i = 0
        while i < scriptTokens.count {
            if scriptTokens[i] == "going", i + 1 < scriptTokens.count, scriptTokens[i + 1] == "to" {
                units.append(.init(coveredThrough: i + 2, emitted: "gonna"))
                i += 2
                continue
            }
            if i > 0, i % 40 == 0 {
                // Dropped word: the ASR missed it entirely, but the speaker did progress past it.
                units.append(.init(coveredThrough: i + 1, emitted: nil))
            } else if i > 0, i % 12 == 0 {
                units.append(.init(coveredThrough: i + 1, emitted: ASRNoise.corrupt(scriptTokens[i])))
            } else {
                units.append(.init(coveredThrough: i + 1, emitted: scriptTokens[i]))
            }
            i += 1
        }
        let builder = TranscriptBuilder()
        builder.speak(units)
        return FixtureTranscript(scriptName: scriptName, scenario: "misrecognition", scriptTokens: scriptTokens, checkpoints: builder.checkpoints)
    }

    static func paragraphSkip(scriptName: String, scriptTokens: [String], scriptIndex: ScriptIndex) -> FixtureTranscript {
        let paragraphs = scriptIndex.paragraphTokenRanges
        let builder = TranscriptBuilder()
        guard paragraphs.count >= 3 else {
            builder.speak(TranscriptBuilder.clean(scriptTokens: scriptTokens, range: 0..<scriptTokens.count))
            return FixtureTranscript(scriptName: scriptName, scenario: "paragraphSkip", scriptTokens: scriptTokens, checkpoints: builder.checkpoints)
        }
        // Speak paragraph 0, skip paragraph 1 entirely, resume from paragraph 2 onward.
        builder.speak(TranscriptBuilder.clean(scriptTokens: scriptTokens, range: paragraphs[0]))
        let resumeStart = paragraphs[2].lowerBound
        builder.speak(TranscriptBuilder.clean(scriptTokens: scriptTokens, range: resumeStart..<scriptTokens.count))
        return FixtureTranscript(scriptName: scriptName, scenario: "paragraphSkip", scriptTokens: scriptTokens, checkpoints: builder.checkpoints)
    }

    /// Ad-libs 20+ off-script words mid-read, then resumes exactly where it left off.
    static func adLibInsertion(scriptName: String, scriptTokens: [String]) -> FixtureTranscript {
        let splitPoint = scriptTokens.count / 2
        let builder = TranscriptBuilder()
        builder.speak(TranscriptBuilder.clean(scriptTokens: scriptTokens, range: 0..<splitPoint))

        let adLibWords = "so yeah i think what i really want to say here is that this whole thing about the weather today has been absolutely wild if you ask me honestly"
            .split(separator: " ").map(String.init)
        precondition(adLibWords.count >= 20)
        let adLibUnits = adLibWords.map { TranscriptBuilder.SpokenUnit(coveredThrough: splitPoint, emitted: $0) }
        builder.speak(adLibUnits)

        builder.speak(TranscriptBuilder.clean(scriptTokens: scriptTokens, range: splitPoint..<scriptTokens.count))
        return FixtureTranscript(scriptName: scriptName, scenario: "adLibInsertion", scriptTokens: scriptTokens, checkpoints: builder.checkpoints)
    }

    /// Speaks through a sentence, repeats the same sentence verbatim, then continues.
    static func repeatedSentence(scriptName: String, scriptTokens: [String], scriptIndex: ScriptIndex) -> FixtureTranscript {
        let builder = TranscriptBuilder()
        // Pick a sentence roughly a third of the way through so there's real content before and after it.
        let targetIndex = scriptIndex.sentences.count / 3
        let sentence = scriptIndex.sentences[targetIndex]

        builder.speak(TranscriptBuilder.clean(scriptTokens: scriptTokens, range: 0..<sentence.tokenEnd))
        let repeatUnits = (sentence.tokenStart..<sentence.tokenEnd).map {
            TranscriptBuilder.SpokenUnit(coveredThrough: sentence.tokenEnd, emitted: scriptTokens[$0])
        }
        builder.speak(repeatUnits)
        builder.speak(TranscriptBuilder.clean(scriptTokens: scriptTokens, range: sentence.tokenEnd..<scriptTokens.count))
        return FixtureTranscript(scriptName: scriptName, scenario: "repeatedSentence", scriptTokens: scriptTokens, checkpoints: builder.checkpoints)
    }

    /// Sustained (~1-in-4, ~25%) corruption throughout a normal, otherwise-linear read —
    /// heavier than `misrecognition`'s ~10% but well short of `adLibInsertion`-grade noise,
    /// reproducing the on-device "cursor gets stuck / slow to transition" report (M4,
    /// docs/MATCHING_ENGINE.md): confidence hovers in the ambiguous middle band for a long
    /// stretch rather than clearly failing, which used to reset the recovery timer on every tick
    /// and could stall indefinitely. Unlike `adLibInsertion`, the reader is never actually
    /// off-script here — ground truth tracks real linear progress.
    static func mediocreStall(scriptName: String, scriptTokens: [String]) -> FixtureTranscript {
        var units: [TranscriptBuilder.SpokenUnit] = []
        for i in 0..<scriptTokens.count {
            if i % 4 == 0 {
                units.append(.init(coveredThrough: i + 1, emitted: ASRNoise.corrupt(scriptTokens[i])))
            } else {
                units.append(.init(coveredThrough: i + 1, emitted: scriptTokens[i]))
            }
        }
        let builder = TranscriptBuilder()
        builder.speak(units)
        return FixtureTranscript(scriptName: scriptName, scenario: "mediocreStall", scriptTokens: scriptTokens, checkpoints: builder.checkpoints)
    }

    /// A long silence (gap in the delta stream) mid-read.
    static func longSilence(scriptName: String, scriptTokens: [String]) -> FixtureTranscript {
        let splitPoint = scriptTokens.count / 2
        let builder = TranscriptBuilder()
        builder.speak(TranscriptBuilder.clean(scriptTokens: scriptTokens, range: 0..<splitPoint))
        builder.pause(seconds: 4.0, expectedCursor: splitPoint)
        builder.speak(TranscriptBuilder.clean(scriptTokens: scriptTokens, range: splitPoint..<scriptTokens.count))
        return FixtureTranscript(scriptName: scriptName, scenario: "longSilence", scriptTokens: scriptTokens, checkpoints: builder.checkpoints)
    }
}

enum FixtureSuite {
    static let all: [FixtureTranscript] = FixtureScripts.all.flatMap { script -> [FixtureTranscript] in
        let index = ScriptIndex.build(from: script.text)
        let tokens = index.tokenTexts
        return [
            FixtureBuilder.cleanRead(scriptName: script.name, scriptTokens: tokens),
            FixtureBuilder.misrecognition(scriptName: script.name, scriptTokens: tokens),
            FixtureBuilder.paragraphSkip(scriptName: script.name, scriptTokens: tokens, scriptIndex: index),
            FixtureBuilder.adLibInsertion(scriptName: script.name, scriptTokens: tokens),
            FixtureBuilder.repeatedSentence(scriptName: script.name, scriptTokens: tokens, scriptIndex: index),
            FixtureBuilder.longSilence(scriptName: script.name, scriptTokens: tokens),
            FixtureBuilder.mediocreStall(scriptName: script.name, scriptTokens: tokens),
        ]
    }
}
