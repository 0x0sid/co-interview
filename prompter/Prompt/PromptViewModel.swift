import Foundation
import Observation
import SwiftUI
import AVFoundation

/// Wires a live/fake transcription stream into the real `SlidingWindowMatcher` and publishes the
/// resulting cursor plus a muted "listening" preview of in-flight (volatile) speech, for
/// `PromptScreen` (§12.4).
///
/// **Deviation from §11.4 (logged in docs/DECISIONS.md, 2026-08-13)**: originally only `.final`
/// deltas were fed to the matcher, per `TranscriptStream`'s "volatile is display-only" contract.
/// Two rounds of on-device `[PromptDebug]` logging showed `.final` results arriving 2-15s apart
/// even during continuous reading — since the cursor only ever moved on `.final`, this alone
/// explained the reported "a lot of delay", and it also meant the matcher's own silence-freeze
/// timer (which only resets on `.final`) fired ~1.5s after nearly every sentence regardless of
/// whether the reader had actually gone quiet, producing the reported "unstable"
/// advancing-then-frozen cycling. Fixed by incrementally feeding the *newly appended* words from
/// each `.volatile` delta to the matcher too (see `start(using:)`), not just `.final` — kept safe
/// against volatile's well-known revision behavior by only ever feeding a strict prefix-extension
/// of what was already fed, and by having the eventual `.final` catch up on anything volatile
/// never got a chance to (a mid-utterance revision, or the tail end of a sentence). This path is
/// exercised only by live devices, not by `SlidingWindowMatcherTests`' fixture-based M1 gate
/// (which only ever calls `advance()` with whole finalized tokens) — the matcher itself
/// (`SlidingWindowMatcher`/`MatcherConfig`) is untouched, so that gate's numbers still hold, but
/// this new call pattern is unverified by it and needs its own on-device confirmation.
///
/// Also runs a lightweight periodic tick (independent of the transcript stream) that calls
/// `matcher.advance(spoken: [], now:)` every 0.5s. Real silence produces no deltas at all — no
/// volatile, no final — so without this the matcher never gets a chance to notice a gap and
/// trigger `.frozen` (§10.4, "the eye contact feature"). The debug replay screen doesn't need this
/// because its fixtures encode empty-token events explicitly; a live stream can't.
///
/// The tick's `now` has to stay in the *same clock domain* the matcher's own gap check uses
/// internally (`SlidingWindowMatcher`'s `lastTokenTimestamp`) — on-device `[PromptDebug]` logging
/// (2026-08-13) showed the tick instead passing wall-clock-since-`start()`, which runs ~0.5-1s
/// ahead of the transcriber's own clock (model/asset setup happens *after* `start()` is called),
/// so the freeze threshold fired early. Fixed by tracking the most recent delta of *either* kind
/// and extrapolating from it, in the delta's own clock — this alone wasn't enough to stop the
/// freeze-cycling (that needed the volatile-feeding change above too), but it's still a real,
/// independent correctness fix for the threshold's timing accuracy.
@MainActor
@Observable
final class PromptViewModel {
    let scriptText: String
    let scriptIndex: ScriptIndex

    private(set) var cursor = PromptCursor(tokenIndex: 0, confidence: 0, state: .holding)

    /// Tokens the reader is *known to have pronounced* — the only thing `ScriptStyling` is allowed
    /// to grey out.
    ///
    /// Deliberately not "everything before the cursor". A real device trace (2026-08-22) had the
    /// matcher jump the cursor 14 → 20 → 26 → 43 → 100 → 119 → 156 while the reader talked
    /// off-script, and a position-based rule greyed ~150 tokens they had never spoken — most of
    /// the script, while they were still at "welcome to Prompter". Only ordinary, small,
    /// `.advancing` steps count as reading; jumps and recoveries move the cursor without marking
    /// anything, so skipped text stays black because it genuinely was not read.
    private(set) var spokenTokenIndices: Set<Int> = []
    /// Recently fed words, used to pair a reacquisition against the clause that supported it.
    private var fedHistory: [String] = []
    /// Token positions a landing crossed, which contextual bridging may never span.
    private var continuityBreaks: Set<Int> = []
    private(set) var listeningText = ""
    private(set) var isRunning = false
    private(set) var isPausedByInterruption = false
    /// User-initiated pause (the bottom bar's Pause button), distinct from
    /// `isPausedByInterruption` (a phone call etc.) — both resolve through the same `resume()`.
    private(set) var isManuallyPaused = false
    private(set) var errorMessage: String?
    private(set) var sessionStartedAt: Date?

    /// §12.4's end-of-session state: the cursor has reached the end of the script on a real
    /// (non-empty) advance, so the take is done. Drives `PromptScreen`'s summary view instead of
    /// a modal — "NO modals during a take" (§12.4) applies to the take itself, but the summary
    /// intentionally replaces the reading UI in place rather than sheeting over it.
    var isSessionComplete: Bool {
        isRunning && !scriptIndex.tokens.isEmpty && cursor.tokenIndex >= scriptIndex.tokens.count
    }

    private var matcher: SlidingWindowMatcher
    private let makeService: () -> Transcribing
    private var service: Transcribing?
    private var consumeTask: Task<Void, Never>?
    private var silenceTickTask: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?

    /// The script's own language, used to choose the recognition locale (M5.12).
    let readingLanguage: ReadingLanguage

    init(scriptText: String, makeService: @escaping () -> Transcribing, readingLanguage: ReadingLanguage = .english) {
        self.scriptText = scriptText
        self.readingLanguage = readingLanguage
        let index = ScriptIndex.build(from: scriptText)
        self.scriptIndex = index
        self.matcher = SlidingWindowMatcher(scriptIndex: index)
        self.makeService = makeService
    }

    /// §11.7 / M4 Step 3: distinctive script vocabulary fed to the transcriber as a recognition
    /// bias (`TranscriptionService` turns this into `AnalysisContext.contextualStrings`) —
    /// proper nouns and unusual words general-purpose dictation otherwise struggles with (real
    /// on-device symptom: "Mimi"/"Hannah" in the owner's own test script getting mangled).
    /// Reuses `MatcherConfig.commonWords` as the "not distinctive" filter — the same list Step
    /// 2's `RecoverySearch` eligibility gate uses — deduplicated, capped at 100 words.
    private var distinctiveVocabulary: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for token in scriptIndex.tokenTexts {
            guard !MatcherConfig.default.commonWords.contains(token) else { continue }
            guard seen.insert(token).inserted else { continue }
            result.append(token)
            if result.count >= 100 { break }
        }
        return result
    }

    /// User-initiated Start — and Restart, which just calls this again: always begins from the
    /// top of the script with a fresh matcher. For continuing an interrupted take with the
    /// cursor preserved instead, see `resume()`.
    func start() {
        isPausedByInterruption = false
        sessionStartedAt = nil
        // A restart re-reads from the top, so nothing has been spoken yet in this take. `resume()`
        // deliberately keeps the record, since that take is continuing rather than restarting.
        spokenTokenIndices = []
        fedHistory = []
        continuityBreaks = []
        beginSession(matcher: SlidingWindowMatcher(scriptIndex: scriptIndex))
    }

    /// Continues the take with the *existing* matcher — cursor, ring buffer, and confidence all
    /// untouched, unlike `start()`. Used both to auto-resume after a phone-call-style
    /// interruption ends with the system reporting it's safe to (§11.8: "auto-pause, preserve
    /// cursor, resume cleanly"), and as a manual "Resume" action otherwise.
    func resume() {
        isPausedByInterruption = false
        isManuallyPaused = false
        beginSession(matcher: matcher)
    }

    /// User-initiated Pause (the bottom bar's Pause button): stops capture without resetting
    /// anything — cursor, matcher, ring buffer all stay put, same as an interruption pause,
    /// just triggered by the user instead of the system. `resume()` continues it either way.
    func pause() {
        guard isRunning else { return }
        consumeTask?.cancel()
        consumeTask = nil
        silenceTickTask?.cancel()
        silenceTickTask = nil
        let activeService = service
        service = nil
        isRunning = false
        isManuallyPaused = true
        Task { await activeService?.stop() }
    }

    /// M4's session coordinator: this is the one thing that changes between `start()` (fresh
    /// matcher) and `resume()` (existing matcher) — everything else about spinning up a take is
    /// identical, so both funnel through here.
    ///
    /// Has to do two things a naive "cancel the old task, spin up the new one" doesn't: (1) fully
    /// await the outgoing service's `stop()` — including its `AVAudioSession.setActive(false)` —
    /// before the incoming service's `start()` calls `setActive(true)` on a brand-new
    /// `AVAudioEngine`, otherwise the two sessions race and `engine.start()` can silently fail
    /// (this was the cause of "Restart doesn't work" on-device); and (2) take the matcher as a
    /// parameter rather than always building a fresh one, so `resume()` can preserve progress.
    /// Moves the cursor, and records which tokens that particular move *proves* were spoken.
    ///
    /// The test is the matcher's own state, not the size of the step. `.advancing` means the
    /// local search tracked continuous reading; `.recovering` means it gave up and jumped to a
    /// new position, which proves nothing about the text in between. So recovery moves the cursor
    /// without marking anything, and skipped text stays black.
    ///
    /// An earlier version also required the step to be `<= forwardCapWithoutRecovery` (6). That
    /// was wrong: the forward cap only applies when the score is *below*
    /// Marks as *spoken* only the script tokens that the words just fed actually landed on.
    ///
    /// **The rule is per word, never per interval.** The previous version inserted the whole span
    /// `previousIndex..<newCursor.tokenIndex` whenever the state was `.advancing`, which infers
    /// "spoken" from cursor movement alone. On the 2026-09-10 device session that greyed **29
    /// tokens at once** on the `155 -> 184 advancing` move at 94.041 s — text the reader had not
    /// said. Grey means "you actually said this"; it may never be deduced from where the cursor
    /// went (§M5.2, docs/MATCHING_ENGINE.md).
    ///
    /// What replaces it: only the words in *this* feed can newly become spoken, so at most
    /// `fedWords.count` tokens are eligible, they are paired positionally back from the new cursor,
    /// and each one is marked only if the word actually resembles the script token it landed on.
    /// A large cursor movement carrying one spoken word therefore greys at most that one word, and
    /// the tokens it skipped over stay dark.
    ///
    /// A paragraph can still go fully grey — but only once every one of its words has been
    /// confirmed individually, which is the intended behaviour rather than a side effect.
    private func applyCursor(_ newCursor: PromptCursor, fedWords: [String] = []) {
        let previousIndex = cursor.tokenIndex

        // Recent history, not just this feed: the words that supported a reacquisition are usually
        // already in the buffer by the time the landing happens (M5.4).
        fedHistory.append(contentsOf: fedWords)
        if fedHistory.count > Self.fedHistoryLimit {
            fedHistory.removeFirst(fedHistory.count - Self.fedHistoryLimit)
        }

        // A landing the reader may not have read through: never bridge across it.
        if newCursor.state == .recovering || newCursor.tokenIndex - previousIndex > MatcherConfig.default.forwardCapWithoutRecovery {
            continuityBreaks.insert(newCursor.tokenIndex)
            continuityBreaks.insert(previousIndex)
        }

        let direct = Self.newlySpokenTokens(
            fedWords: fedHistory,
            from: previousIndex,
            to: newCursor.tokenIndex,
            state: newCursor.state,
            scriptTokens: scriptIndex.tokenTexts
        )
        spokenTokenIndices.formUnion(direct)

        let bridged = Self.bridgedTokens(
            directlySpoken: spokenTokenIndices,
            continuityBreaks: continuityBreaks,
            maximumGap: Self.maximumBridgedTokens
        ).subtracting(spokenTokenIndices)
        spokenTokenIndices.formUnion(bridged)

        #if DEBUG
        // Direct and inferred coverage are reported separately, so inferred is never mistaken for
        // recognition in evidence (M5.4, docs/DECISIONS.md).
        if !direct.isEmpty || !bridged.isEmpty {
            let tokens = scriptIndex.tokenTexts
            func describe(_ set: Set<Int>) -> String {
                set.sorted().map { "\($0):\($0 < tokens.count ? tokens[$0] : "?")" }.joined(separator: " ")
            }
            print("[Styling] applyCursor \(previousIndex)->\(newCursor.tokenIndex) \(newCursor.state) fed=\(fedWords) direct=[\(describe(direct))] bridged=[\(describe(bridged))]")
        } else if newCursor.tokenIndex > previousIndex {
            print("[Styling] applyCursor \(previousIndex)->\(newCursor.tokenIndex) \(newCursor.state) fed=\(fedWords) direct=NONE bridged=NONE (skipped text stays dark)")
        }
        #endif

        cursor = newCursor
    }

    /// The pure rule behind `applyCursor`, extracted so it can be tested directly rather than only
    /// through a live session. Returns the script tokens these words confirm as **directly** spoken.
    ///
    /// **Evidence decides, not the cursor state.** Recovery must not grey the interval it skipped,
    /// but the words it was given — and the words still in recent history that supported the
    /// reacquisition — are real speech that aligned to real script tokens. Both properties come from
    /// one cap: eligibility never reaches further back than the supplied words, so a jump cannot
    /// colour the interval it crossed, whatever its state.
    ///
    /// `fedWords` should carry the recent **history**, not only the newest feed: a reacquisition fed
    /// `["off","script"]` was supported by a whole clause still in the buffer, and marking only two
    /// tokens leaves the rest of that clause dark (M5.4, docs/DECISIONS.md).
    ///
    /// A single failed pair is treated as an ASR **substitution** and skipped; **two consecutive**
    /// failures stop the walk, which is the signature of an insertion shifting every earlier pair.
    /// The earlier stop-at-first-failure rule was too strict — it discarded correctly aligned words
    /// after any single stumble, which is one of the two causes of the dark sentence in the
    /// 2026-09-12 screenshots.
    nonisolated static func newlySpokenTokens(
        fedWords: [String],
        from previousIndex: Int,
        to newIndex: Int,
        state: PromptCursor.State,
        scriptTokens: [String]
    ) -> Set<Int> {
        guard newIndex > previousIndex, !fedWords.isEmpty else { return [] }
        var result: Set<Int> = []
        let earliestEligible = max(0, newIndex - fedWords.count)
        var tokenIndex = newIndex - 1
        var wordIndex = fedWords.count - 1
        var consecutiveFailures = 0
        var sawFailure = false
        while tokenIndex >= earliestEligible, wordIndex >= 0 {
            // **The bar rises after the first failure.** Pairs before any failure are anchored to
            // the newest word — the best-supported pairing available, since it is the one the
            // matcher advanced on. It is *not* certain: the matcher can advance on a wrong
            // alignment, and when it does this pairing is wrong too. What the anchor buys is that
            // these pairs rest on a single decision rather than on a chain of them. Once a pair
            // fails the alignment may also have shifted, so every later pair compounds a second
            // source of error and must be strong rather than merely plausible.
            //
            // This replaces "one mismatch = substitution, two = insertion", which was never a proven
            // classification. The concrete case it fixes: "this is erm a longer test" against "this
            // is a longer test" shifts the pairing, and `"is"` against `"this"` scores **exactly
            // 0.5** — the admission floor — so it was marked despite being the wrong token. At
            // `perTokenMatchThreshold` it is rejected, and the independently supported words later in
            // the clause are still marked.
            let bar = sawFailure ? shiftedPairMinSimilarity : spokenWordMinSimilarity
            let matched = tokenIndex >= 0 && tokenIndex < scriptTokens.count
                && ConfidenceModel.rawSimilarity(fedWords[wordIndex], scriptTokens[tokenIndex]) >= bar
            if matched {
                result.insert(tokenIndex)
                consecutiveFailures = 0
            } else {
                sawFailure = true
                consecutiveFailures += 1
                if consecutiveFailures >= 2 { break }
            }
            tokenIndex -= 1
            wordIndex -= 1
        }
        return result
    }

    /// Fills short gaps **between two directly confirmed tokens**, so one misrecognised word does
    /// not leave a clause dark while the reader demonstrably read through it (M5.4).
    ///
    /// Strictly bounded: at most `maximumBridgedTokens` contiguous dark tokens, only with a direct
    /// anchor on **both** sides, and never across a `continuityBreak` — which is where a recovery
    /// landed or a jump larger than the forward cap occurred. A deliberately skipped sentence is a
    /// break, so it stays dark. Ambiguity leaves tokens unmarked.
    nonisolated static func bridgedTokens(
        directlySpoken: Set<Int>,
        continuityBreaks: Set<Int>,
        maximumGap: Int
    ) -> Set<Int> {
        guard directlySpoken.count >= 2 else { return [] }
        let sorted = directlySpoken.sorted()
        var bridged: Set<Int> = []
        for (before, after) in zip(sorted, sorted.dropFirst()) {
            let gap = after - before - 1
            guard gap > 0, gap <= maximumGap else { continue }
            let span = (before + 1)...(after - 1)
            // A break anywhere inside the gap, or at its far anchor, means the reader may have
            // jumped rather than read through.
            guard !span.contains(where: { continuityBreaks.contains($0) }),
                  !continuityBreaks.contains(after) else { continue }
            bridged.formUnion(span)
        }
        return bridged
    }

    /// Longest run of unconfirmed tokens that may be inferred as read. About one clause.
    nonisolated static let maximumBridgedTokens = 6

    /// Similarity a pair must reach **after** an earlier pair in the same walk has failed, when the
    /// alignment may have shifted. Deliberately `MatcherConfig.perTokenMatchThreshold` (0.8) — a real
    /// match, not "the same neighbourhood" — because at that point position is no longer evidence.
    nonisolated static let shiftedPairMinSimilarity = 0.8

    /// How many recently fed words are retained for pairing. Wider than `alignmentWindow` so a
    /// reacquisition supported by a clause still in the matcher's buffer can be mapped, but bounded
    /// so it can never reach back across a whole paragraph.
    nonisolated static let fedHistoryLimit = 16

    /// How closely a fed word must resemble the script token it landed on before that token is
    /// shown as spoken. Deliberately the same 0.5 "is this even the same word?" bar as
    /// `MatcherConfig.freshestTokenMinSimilarity`, and for the same reason: streaming ASR emits the
    /// right word imperfectly all the time ("write" for "written" = 0.71), and demanding a full
    /// match would leave genuinely-read words stubbornly black.
    nonisolated static let spokenWordMinSimilarity = 0.5

    private func beginSession(matcher sessionMatcher: SlidingWindowMatcher) {
        let newService = makeService()
        let outgoingService = service
        consumeTask?.cancel()
        silenceTickTask?.cancel()

        matcher = sessionMatcher
        cursor = sessionMatcher.current
        listeningText = ""
        errorMessage = nil
        service = newService
        isRunning = true
        if sessionStartedAt == nil {
            sessionStartedAt = Date()
        }

        registerInterruptionObserverIfNeeded()

        let sessionStart = Date()

        // Temporary `[PromptDebug]` instrumentation (owner-requested, 2026-08-13) to diagnose
        // reported delay/instability on-device: every recognition event and every cursor move,
        // each tagged with both wall-clock elapsed (when *this app* observed it) and the delta's
        // own audio-relative timestamp (when the analyzer says the audio actually was) — the gap
        // between successive `FINAL` timestamps is the real measure of ASR finalization delay,
        // separate from anything in the matcher. Not gated behind anything beyond `#if DEBUG`
        // (this whole screen already is) — intended to be read from Xcode's console during a
        // device test, then removed or demoted once the root cause is confirmed.
        // **Gated for real as of M5.11.** The comment above used to claim this was already
        // `#if DEBUG`-gated "because this whole screen is". It was not: a nesting scan found this
        // `print` outside every `#if DEBUG` block, so a Release build shipped the whole
        // `[PromptDebug]` stream — every recognition event, including transcript text, and every
        // cursor move — to the device console. That is transcript logging in a shipping build.
        func debugLog(_ message: String) {
            #if DEBUG
            let elapsed = Date().timeIntervalSince(sessionStart)
            print(String(format: "[PromptDebug %7.3fs] %@", elapsed, message))
            #endif
        }

        let config = MatcherConfig.default
        debugLog("SESSION START — \(scriptIndex.tokens.count) tokens, \(scriptIndex.sentences.count) sentences — advanceThreshold=\(config.advanceThreshold) recoveryTriggerThreshold=\(config.recoveryTriggerThreshold) recoveryJumpThreshold=\(config.recoveryJumpThreshold) (context for reading confidence/state on every CURSOR line below: >= advanceThreshold advances, < recoveryTriggerThreshold arms recovery, between the two holds)")

        // Anchors the transcriber's own audio-relative clock to wall-clock time, updated on every
        // delta (volatile *or* final) so the silence tick can extrapolate "now" in that same clock
        // domain and treat ongoing volatile speech as activity, not silence. Plain locals captured
        // by both tasks below — safe because both closures stay MainActor-isolated (created inside
        // this MainActor method, not detached), same as `cursor`/`listeningText` already are.
        var lastActivityAudioTimestamp: TimeInterval = 0
        var lastActivityWallClock = Date()

        consumeTask = Task {
            await outgoingService?.stop()
            var lastFinalAudioTimestamp: TimeInterval?
            // The normalized words already fed to the matcher from `.volatile` deltas for the
            // *current* in-flight utterance — reset to `[]` on every `.final` (a fresh utterance
            // starts next). Only ever advanced when we actually feed something (see below), so it
            // always reflects the true low-water-mark the next `.final` needs to catch up from.
            var volatileWordsFedToMatcher: [String] = []

            do {
                // **The script's language, not the device's (M5.12).** This previously passed
                // `Locale.current`, i.e. the interface locale, so a French script on an English
                // phone was transcribed with an English model. `SpeechAssetManager.supportedLocale`
                // resolves this to a locale the installed transcriber actually supports and
                // **throws** if none is close enough — there is no silent substitution.
                let stream = try await newService.start(locale: readingLanguage.requestedLocale, contextualStrings: distinctiveVocabulary)
                for await delta in stream {
                    lastActivityAudioTimestamp = delta.timestamp
                    lastActivityWallClock = Date()
                    switch delta.kind {
                    case .volatile:
                        debugLog("VOLATILE  audio_ts=\(String(format: "%7.3f", delta.timestamp))s  text=\"\(delta.text)\"")
                        listeningText = delta.text

                        let words = Tokenizer.normalize(delta.text)
                        // Withhold the trailing word — the one word still in a position to be
                        // revised by whatever comes next in this same utterance (docs/ARCHITECTURE.md,
                        // "Volatile reconciliation") — it only becomes safe to feed once a later
                        // word appears after it (proving it settled) or the eventual `.final`
                        // confirms it via the catch-up diff below.
                        let stableWordCount = max(0, words.count - 1)
                        let alreadyFed = volatileWordsFedToMatcher.count
                        // Only feed the new tail if this volatile update is a strict extension of
                        // what we already fed — if the ASR revised earlier words instead of just
                        // appending, skip it silently rather than feed something possibly wrong;
                        // the next `.final` will catch up on whatever never got fed.
                        if stableWordCount > alreadyFed, Array(words.prefix(alreadyFed)) == volatileWordsFedToMatcher {
                            let newWords = Array(words[alreadyFed..<stableWordCount])
                            let newTokens = newWords.map { Token($0, at: delta.timestamp) }
                            withAnimation(.easeInOut(duration: 0.2)) {
                                applyCursor(sessionMatcher.advance(spoken: newTokens, now: delta.timestamp), fedWords: newWords)
                            }
                            volatileWordsFedToMatcher = Array(words[0..<stableWordCount])
                            debugLog("VOLATILE-FED \(newTokens.count) word(s) \"\(newWords.joined(separator: " "))\"  cursor -> token \(cursor.tokenIndex)  confidence=\(String(format: "%.2f", cursor.confidence))  state=\(cursor.state)")
                        }
                    case .final:
                        let sinceLastFinal = lastFinalAudioTimestamp.map { String(format: "%.3fs", delta.timestamp - $0) } ?? "n/a"
                        lastFinalAudioTimestamp = delta.timestamp
                        debugLog("FINAL     audio_ts=\(String(format: "%7.3f", delta.timestamp))s  gap_since_prev_final=\(sinceLastFinal)  tokens=\(delta.tokens.count)  text=\"\(delta.text)\"")
                        listeningText = ""

                        // A same-length correction (e.g. volatile fed "rid", final corrects it to
                        // "rides") isn't caught by comparing counts alone — walk word-by-word and
                        // re-feed from the first point of disagreement, not just from the end of
                        // what was already fed, so a same-position correction isn't silently lost.
                        var matchingPrefixCount = 0
                        while matchingPrefixCount < volatileWordsFedToMatcher.count,
                              matchingPrefixCount < delta.tokens.count,
                              volatileWordsFedToMatcher[matchingPrefixCount] == delta.tokens[matchingPrefixCount].text {
                            matchingPrefixCount += 1
                        }
                        let catchUpTokens = Array(delta.tokens.suffix(from: matchingPrefixCount))
                        volatileWordsFedToMatcher = []

                        let before = cursor
                        withAnimation(.easeInOut(duration: 0.25)) {
                            applyCursor(sessionMatcher.advance(spoken: catchUpTokens, now: delta.timestamp), fedWords: catchUpTokens.map(\.text))
                        }
                        let after = cursor
                        debugLog("CURSOR    (final, \(catchUpTokens.count) new of \(delta.tokens.count) total) token \(before.tokenIndex) -> \(after.tokenIndex) (Δ\(after.tokenIndex - before.tokenIndex))  confidence=\(String(format: "%.2f", after.confidence))  state=\(after.state)")
                    }
                }
            } catch {
                errorMessage = "\(error)"
                debugLog("ERROR     \(error)")
            }
            isRunning = false
            debugLog("SESSION END")
        }

        silenceTickTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                if Task.isCancelled { break }
                let estimatedNow = lastActivityAudioTimestamp + Date().timeIntervalSince(lastActivityWallClock)
                let before = cursor
                cursor = sessionMatcher.advance(spoken: [], now: estimatedNow)
                if cursor.state != before.state {
                    debugLog("TICK      state \(before.state) -> \(cursor.state) (silence check, no new speech, estimated_audio_now=\(String(format: "%.3f", estimatedNow))s)")
                }
            }
        }
    }

    private func registerInterruptionObserverIfNeeded() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // `Notification` itself isn't `Sendable` (its `userInfo` is `[AnyHashable: Any]`), so
            // it can't cross into the `@MainActor` `Task` below directly — parse out just the two
            // plain, Sendable values `handleInterruption` actually needs right here instead.
            guard let info = notification.userInfo,
                  let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
            let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume)
            Task { @MainActor in
                self?.handleInterruption(type: type, shouldResume: shouldResume)
            }
        }
    }

    /// The session-level counterpart to `AudioCaptureService`'s own interruption handling: that
    /// component already stops its engine/session immediately on `.began` (releasing the mic for
    /// the call) and, as part of tearing down, unregisters its *own* observer — so nothing is
    /// left listening for the matching `.ended` event to know when it's safe to resume. This
    /// observer lives for the whole session instead, independent of any one `Transcribing`
    /// instance, specifically so it can react to `.ended` (§11.8: "auto-pause, preserve cursor,
    /// resume cleanly").
    private func handleInterruption(type: AVAudioSession.InterruptionType, shouldResume: Bool) {
        switch type {
        case .began:
            guard isRunning else { return }
            isPausedByInterruption = true
        case .ended:
            guard isPausedByInterruption else { return }
            if shouldResume {
                resume()
            }
            // else: stay paused. The matcher/cursor are untouched either way, and `resume()` is
            // still reachable from the UI's "Resume" action.
        @unknown default:
            break
        }
    }

    func stop() {
        consumeTask?.cancel()
        consumeTask = nil
        silenceTickTask?.cancel()
        silenceTickTask = nil
        isPausedByInterruption = false
        isManuallyPaused = false
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        interruptionObserver = nil
        let activeService = service
        service = nil
        isRunning = false
        Task { await activeService?.stop() }
    }
}
