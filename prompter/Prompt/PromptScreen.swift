import SwiftUI
import SwiftData

/// §12.4's production prompt screen — the product. Text column pinned toward the top edge
/// (minimizes eye-line offset when the phone is mounted at the lens), pinch-to-scale persisted
/// to `AppSettings`, single auto-hiding bottom bar, mirror toggle, no
/// modals during a take, in-place end-of-session summary, Reduce Motion + VoiceOver support.
struct PromptScreen: View {
    @State private var viewModel: PromptViewModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @Query private var settingsQuery: [AppSettings]

    @State private var isMirrored = false
    @State private var fontScale: CGFloat = 1.0
    @State private var pinchBaseline: CGFloat = 1.0
    @State private var blockHeights: [Int: CGFloat] = [:]
    @State private var prefixMeasurement = PrefixMeasurement(block: -1, token: -1, height: 0)
    @State private var scrollPosition = ScrollPosition(idType: Int.self)
    /// Scroll ownership and the rule for handing it back (M5.7, docs/DECISIONS.md). Automatic
    /// following resumes on fresh reading evidence inside the region the reader chose; the
    /// "Resume following" button remains an immediate override, not a requirement.
    @State private var ownership = ScrollOwnership()
    /// Latest visible content rect, used to work out which tokens the reader repositioned to.
    @State private var visibleRect: CGRect = .zero
    /// Latest scroll phase — resumption is forbidden unless this is `.idle`.
    @State private var scrollPhase: ScrollPhase = .idle
    /// Timestamps of recent applied targets, used to pace the following animation to the reader.
    @State private var lastTargetAt: Date?
    @State private var observedInterval: TimeInterval = 0.5
    /// Last offset actually applied, so an unchanged target is not re-issued.
    @State private var lastAppliedOffset: CGFloat?
    @State private var viewportHeight: CGFloat = 0
    @State private var showControls = true
    @State private var hideControlsTask: Task<Void, Never>?
    @State private var didFireCompletion = false
    @State private var hasAutoStarted = false

    /// Optional hook for callers (the Demo flow) that need to know when the take reaches the end
    /// of the script, without `PromptScreen` itself needing to know anything about Demo.
    var onSessionComplete: (() -> Void)?
    private let textDirectionOverride: ScriptTextDirection
    /// Nil for the bundled demo, which is unlimited and unmetered by design.
    private let usage: UsageTracker?
    @Environment(\.scenePhase) private var scenePhase

    init(
        scriptText: String,
        makeService: @escaping () -> Transcribing,
        textDirectionOverride: ScriptTextDirection = .auto,
        readingLanguage: ReadingLanguage = .english,
        usage: UsageTracker? = nil,
        onSessionComplete: (() -> Void)? = nil
    ) {
        self.usage = usage
        _viewModel = State(initialValue: PromptViewModel(scriptText: scriptText, makeService: makeService, readingLanguage: readingLanguage))
        self.textDirectionOverride = textDirectionOverride
        self.onSessionComplete = onSessionComplete
    }

    private var settings: AppSettings? { settingsQuery.first }
    private var palette: OutdoorMode.Palette { OutdoorMode.palette(outdoor: settings?.outdoorMode ?? false) }
    /// M5.1-D: resolved once per script (not per render) — the script's own text doesn't change
    /// mid-take, so this is a pure function of `viewModel.scriptText`/the override.
    private var resolvedTextDirection: LayoutDirection {
        TextDirectionDetector.resolvedDirection(for: viewModel.scriptText, override: textDirectionOverride)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                palette.background.ignoresSafeArea()

                if viewModel.isSessionComplete {
                    summaryView
                } else {
                    readingLayout(geometry: geometry)
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .ignoresSafeArea(edges: .bottom)
        .onAppear {
            isMirrored = settings?.mirrorDefault ?? false
            fontScale = settings?.fontScale ?? 1.0
            scheduleAutoHide()
            // P0 fix (M5.1): arriving here already means the user chose "Start" once, upstream
            // (the editor, the debug screen, or Demo's permission flow) — requiring a *second*,
            // easy-to-miss tap on the auto-hiding bottom bar made the whole take unreachable in
            // practice. Auto-start immediately; the bottom bar's primary button still works as
            // Pause/Resume from here on.
            //
            // `hasAutoStarted` (not `viewModel.isRunning`) guards this: a real device log showed
            // back-to-back "SESSION START" pairs with no gap between them, meaning `.onAppear`
            // fired more than once for the same screen instance and re-triggered `start()`
            // (a fresh matcher, cursor reset to 0) each time — most likely `NavigationLink`
            // re-evaluating its destination closure, a known SwiftUI behavior. `isRunning` alone
            // doesn't defend against this if the second firing lands before the first `start()`'s
            // synchronous state update is visible; a view-instance-scoped flag does.
            if !hasAutoStarted {
                hasAutoStarted = true
                // The allowance was checked before navigating here; a take that is allowed to start
                // is allowed to finish, so this never refuses mid-flight.
                usage?.startTake()
                viewModel.start()
            }
        }
        .onChange(of: viewModel.isSessionComplete) { _, complete in
            guard complete, !didFireCompletion else { return }
            didFireCompletion = true
            onSessionComplete?()
        }
        .onChange(of: viewModel.isPausedByInterruption || viewModel.isManuallyPaused) { _, paused in
            AccessibilityNotification.Announcement(paused ? "Paused" : "Resumed").post()
        }
        .onChange(of: scenePhase) { _, phase in
            // Background time is not metered. Ordinary speech pauses and off-script talking are, as
            // they are part of an active take.
            if phase == .active { if viewModel.isRunning { usage?.resume() } } else { usage?.suspend() }
        }
        .onChange(of: viewModel.isManuallyPaused || viewModel.isPausedByInterruption) { _, paused in
            if paused { usage?.suspend() } else if viewModel.isRunning { usage?.resume() }
        }
        .onDisappear {
            hideControlsTask?.cancel()
            usage?.endTake()
            viewModel.stop()
        }
    }

    // MARK: Reading layout

    private func readingLayout(geometry: GeometryProxy) -> some View {
        // M5.1: previously capped to 0.56 * screen height with a Spacer below — once the cursor
        // advanced near the top of that capped box, the remaining ~44% of the screen was dead
        // Spacer, not scrollable text. That read as a "huge empty white space" bug on-device.
        // The text column now fills the full available height so there's always real content to
        // scroll into.
        ZStack(alignment: .bottom) {
            // **Top inset is the safe area plus the compact control row, nothing more** (M5.10).
            // The previous layout left a large empty band above the first line.
            //
            // No pacing or animation value is touched to compensate. `viewportHeight` is measured
            // by the `GeometryReader` *inside* `textColumn`, so it already excludes this padding —
            // `readingLineFraction` therefore still places the reading line at 12 % of the
            // **scrollable** area, which now begins directly below these controls. That is the
            // correct coordinate space; changing the inset needs no change to `readingOffset`.
            textColumn
                .padding(.top, geometry.safeAreaInsets.top + Self.topControlRowHeight + 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .contentShape(Rectangle())
                .onTapGesture { revealControls() }
                .gesture(pinchGesture)

            // Unobtrusive, and only while the reader has taken the scroll over. It is the one
            // affordance that says the page has stopped following — without it, a detached view
            // looks identical to a broken one.
            if ownership.isManuallyDetached {
                Button {
                    resumeFollowing()
                } label: {
                    Label("Resume following", systemImage: "arrow.down.to.line")
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(palette.ink.opacity(0.85)))
                        .foregroundStyle(palette.background)
                }
                .padding(.bottom, showControls ? 96 : 28)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if showControls {
                bottomBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // Compact close + status, pinned to the top. Laid out above the text but never over it:
        // the text column's top inset reserves exactly this row's height.
        .overlay(alignment: .top) {
            topBar
                .padding(.top, geometry.safeAreaInsets.top)
        }
        .animation(.easeInOut(duration: 0.2), value: showControls)
        .animation(.easeInOut(duration: 0.2), value: ownership.isManuallyDetached)
    }

    private var textColumn: some View {
        let direction = resolvedTextDirection
        let columnAlignment: HorizontalAlignment = direction == .rightToLeft ? .trailing : .leading
        let textAlignment: TextAlignment = direction == .rightToLeft ? .trailing : .leading

        return ScrollView {
                LazyVStack(alignment: columnAlignment, spacing: Self.blockSpacing) {
                    ForEach(sentenceBlocks) { block in
                        block.text
                            .background(GeometryReader { blockGeometry in
                                Color.clear
                                    // Rendered-line measurement for the block being read: the same
                                    // text up to the current word, laid out at the same width and
                                    // font, so its height is the reading line's real offset.
                                    .overlay(alignment: .topLeading) {
                                        if block.id == currentSentenceIndex {
                                            Text(ScriptStyling.prefixOfCurrentSentence(
                                                rawText: viewModel.scriptText,
                                                scriptIndex: viewModel.scriptIndex,
                                                cursor: viewModel.cursor
                                            ))
                                            .font(Typography.reading(readingFontSize, face: .hankenGrotesk))
                                            .multilineTextAlignment(textAlignment)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .frame(width: blockGeometry.size.width, alignment: .topLeading)
                                            .background(GeometryReader { prefixGeometry in
                                                Color.clear.preference(
                                                    key: PrefixHeightPreference.self,
                                                    value: PrefixMeasurement(
                                                        block: block.id,
                                                        token: viewModel.cursor.tokenIndex,
                                                        height: prefixGeometry.size.height
                                                    )
                                                )
                                            })
                                            .hidden()
                                        }
                                    }
                            })
                            .font(Typography.reading(readingFontSize, face: .hankenGrotesk))
                            .multilineTextAlignment(textAlignment)
                            .frame(maxWidth: .infinity, alignment: Alignment(horizontal: columnAlignment, vertical: .center))
                            .padding(.top, block.isFirstInParagraph ? Self.paragraphSpacing : 0)
                            // Fades each word to grey as it is confirmed spoken. Keyed to the
                            // *count of spoken tokens*, because that is what the colour actually
                            // depends on now — keying it to the sentence index (a leftover from
                            // the earlier sentence-based rule) meant mid-sentence words changed
                            // colour with no animation running at all, so they snapped instead of
                            // fading. Safe to fire per word here, unlike the old travelling
                            // marker: grey is monotonic now, a word never reverts to black, so
                            // there is nothing to flicker between.
                            .animation(.easeInOut(duration: 0.45), value: viewModel.spokenTokenIndices.count)
                            .id(block.id)
                            // Full block height *including* its paragraph padding, in content
                            // coordinates — this is what `contentOffset(for:)` sums to find where a
                            // block starts in the scroll content.
                            .background(GeometryReader { full in
                                Color.clear.preference(key: BlockHeightPreference.self, value: [block.id: full.size.height])
                            })
                    }
                    // Trailing space so the final lines can still be scrolled up to the reading
                    // position: everything below the reading line must be fillable, or the last
                    // sentence can never reach it.
                    Color.clear.frame(height: max(0, viewportHeight * (1 - Self.readingLineFraction)))
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: 560, alignment: Alignment(horizontal: columnAlignment, vertical: .center))
                .frame(maxWidth: .infinity)
            }
            .onPreferenceChange(PrefixHeightPreference.self) { measurement in
                prefixMeasurement = measurement
            }
            .onPreferenceChange(BlockHeightPreference.self) { heights in
                blockHeights.merge(heights) { _, new in new }
            }
            .background(GeometryReader { viewportGeometry in
                Color.clear
                    .onAppear { viewportHeight = viewportGeometry.size.height }
                    .onChange(of: viewportGeometry.size.height) { _, height in viewportHeight = height }
            })
            .environment(\.layoutDirection, direction)
            .scrollPosition($scrollPosition)
            // Any touch hands ownership to the reader immediately, cancelling whatever automatic
            // animation is in flight. `simultaneousGesture` so it never competes with the
            // ScrollView's own drag or its deceleration — it only observes.
            .simultaneousGesture(
                DragGesture(minimumDistance: 1).onChanged { _ in
                    if !ownership.isManuallyDetached {
                        ownership.beginManualInteraction()
                        #if DEBUG
                        print(String(format: "[ScrollOwner] %@ user -> manual (automatic following suspended)", Self.stamp()))
                        #endif
                    }
                }
            )
            .onScrollGeometryChange(for: CGRect.self, of: \.visibleRect) { _, rect in
                visibleRect = rect
            }
            .onScrollPhaseChange { _, phase in
                scrollPhase = phase
                // The chosen region is only meaningful once the view has actually settled —
                // sampling it mid-flick would record whatever happened to be passing.
                if phase == .idle, ownership.isManuallyDetached, ownership.isInteracting {
                    let region = visibleTokenRange()
                    ownership.endManualInteraction(visibleTokens: region)
                    #if DEBUG
                    if let region {
                        print(String(format: "[ScrollOwner] %@ settled — chosen region tokens %d..<%d (awaiting %d fresh in-region advances)",
                                     Self.stamp(), region.lowerBound, region.upperBound, ScrollOwnership.resumeEvidenceCount))
                    } else {
                        print(String(format: "[ScrollOwner] %@ settled — no geometry, rule not armed (Resume following still available)", Self.stamp()))
                    }
                    #endif
                }
            }
            .onChange(of: viewModel.cursor) { _, cursor in
                // Resumption is driven by *cursor* updates, not by offset changes: the evidence is
                // that the reader is reading here, and a suppressed offset produces no signal.
                guard let resumption = ownership.observeCursor(
                    token: cursor.tokenIndex,
                    isAdvancing: cursor.state == .advancing,
                    scrollIsIdle: scrollPhase == .idle
                ) else { return }
                #if DEBUG
                print(String(format: "[ScrollOwner] %@ RESUME — %d fresh advances (tokens %d->%d) inside chosen region %d..<%d",
                             Self.stamp(), resumption.evidenceCount, resumption.firstToken, resumption.lastToken,
                             resumption.chosenRegion.lowerBound, resumption.chosenRegion.upperBound))
                #endif
                guard let offset = readingOffset else { return }
                // **The resume glide owns this transition and the pacing state it implies (M5.9).**
                //
                // Previously these were set to `nil`, which had the opposite effect: the cursor
                // change that triggered the resume also changes `readingOffset`, so
                // `onChange(of: readingOffset)` fired in the same frame, found `lastAppliedOffset`
                // cleared, passed the no-op check, rewrote the pacing state a second time — the
                // `onChange(of: Optional<CGFloat>) action tried to update multiple times per frame`
                // warning in the 2026-09-13 capture — and re-issued the same target with the
                // *following* animation, overwriting the recovery glide the reader was meant to see.
                //
                // Recording the glide's own target instead makes the existing M5.4 no-op
                // suppression do the work: a duplicate callback for the same position is recognised
                // and dropped, while a genuinely newer target still differs by more than
                // `offsetEpsilon` and is followed normally.
                lastTargetAt = Date()
                lastAppliedOffset = offset
                withAnimation(ScrollAnimator.recovery(reduceMotion: reduceMotion)) {
                    scrollPosition.scrollTo(y: offset)
                }
            }
            .onChange(of: readingOffset) { _, offset in
                guard let offset else { return }
                // While the reader owns the scroll, targets are computed but never applied, so a
                // drag is not overwritten and nothing snaps back on release.
                guard !ownership.isManuallyDetached else {
                    #if DEBUG
                    print(String(format: "[Scroll] token=%d SUPPRESSED (manual ownership) targetY=%.1f evidence=%d/%d",
                                 viewModel.cursor.tokenIndex, offset,
                                 ownership.evidence.count, ScrollOwnership.resumeEvidenceCount))
                    #endif
                    return
                }
                applyScroll(to: offset)
            }
            .scaleEffect(x: isMirrored ? -1 : 1, y: 1)
    }

    private var readingFontSize: CGFloat { 34 * fontScale }

    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                fontScale = min(max(pinchBaseline * value, 0.7), 2.2)
            }
            .onEnded { _ in
                pinchBaseline = fontScale
                if let settings {
                    settings.fontScale = fontScale
                    try? modelContext.save()
                }
            }
    }

    private var sentenceBlocks: [ScriptStyling.SentenceBlock] {
        ScriptStyling.sentenceBlocks(
            rawText: viewModel.scriptText,
            scriptIndex: viewModel.scriptIndex,
            cursor: viewModel.cursor,
            spokenTokenIndices: viewModel.spokenTokenIndices,
            palette: palette
        )
    }

    /// Where the page should sit: which block to align, and at what unit point inside it.
    ///
    /// **Computed from measured geometry, not a fixed fraction.** `scrollTo(id:anchor:)` aligns the
    /// unit point `a` of the *block* with the same unit point `a` of the *viewport*. To put the
    /// reading position — which sits a fraction `p` through a block of height `H` — at viewport
    /// fraction `F` of viewport height `V`:
    ///
    /// ```
    ///   blockTop + a·H = a·V          (what scrollTo guarantees)
    ///   blockTop + p·H = F·V          (what we want)
    ///   =>  a = (F·V − p·H) / (V − H)
    /// ```
    ///
    /// This is why the earlier attempt failed and was reverted. It swept the anchor *with reading
    /// progress alone*, which is the `p` term without the `H` and `V` terms — and for a block
    /// shorter than the viewport (`H < V`) that expression moves the page the wrong way, which is
    /// exactly the "it scrolls up instead of down" report. With `H` and `V` measured, the sign is
    /// handled by the algebra instead of by luck.
    ///
    /// It also fixes the anchoring complaint directly: a long sentence is one block, so anchoring
    /// its *start* left the reader drifting many rendered lines below the reading position by the
    /// end of it. ¶1's second sentence alone spans tokens 3-35.
    private struct ScrollTarget: Equatable {
        let sentenceIndex: Int
        let anchorY: CGFloat
    }

    /// Applies a target, paced to the reader's own observed cadence.
    ///
    /// Targets arrive one rendered line at a time (the prefix height advances in whole lines), so
    /// the animation between them must still be running when the next lands — otherwise each line
    /// is a separate settle, which is the "stepped" motion reported. `observedInterval` is an
    /// exponential average of the gap between recent targets, clamped by `ScrollAnimator`, so the
    /// motion tracks reading pace without any fixed-speed or WPM setting.
    private func applyScroll(to offset: CGFloat) {
        // **An unchanged target must not restart the animation.** The device log shows the same
        // offset requested for several consecutive tokens — `targetY=14.7` across tokens 4-8 and
        // `targetY=643.0` across tokens 60-64 — because `readingOffset` briefly returns `nil` while
        // the prefix is re-measured for the new token, so `onChange` fires again with the same
        // value. Re-issuing it restarted the in-flight ramp from rest each time, which is motion
        // lost for no movement (M5.4).
        if let applied = lastAppliedOffset, abs(applied - offset) < Self.offsetEpsilon {
            #if DEBUG
            print(String(format: "[Scroll] token=%d unchanged targetY=%.1f — not re-issued", viewModel.cursor.tokenIndex, offset))
            #endif
            return
        }

        let now = Date()
        // **Pace from meaningful movement, not from every callback.** Counting no-op callbacks
        // dragged the estimate toward the minimum and made the ramp shorter than the reader's
        // actual cadence, so the motion finished early and waited — which reads as stopping.
        if let last = lastTargetAt {
            let gap = now.timeIntervalSince(last)
            observedInterval = min(max(0.7 * observedInterval + 0.3 * gap, ScrollAnimator.minimumFollowInterval), ScrollAnimator.maximumFollowInterval)
        }
        lastTargetAt = now
        lastAppliedOffset = offset

        let isRecovery = viewModel.cursor.state == .recovering
        let animation = isRecovery
            ? ScrollAnimator.recovery(reduceMotion: reduceMotion)
            : ScrollAnimator.following(interval: observedInterval, reduceMotion: reduceMotion)

        #if DEBUG
        print(String(
            format: "[Scroll] token=%d block=%d prefixH=%.0f blockTop=%.0f targetY=%.1f interval=%.2fs owner=auto transition=%@",
            viewModel.cursor.tokenIndex, currentSentenceIndex, prefixMeasurement.height,
            contentOffset(ofBlock: currentSentenceIndex), offset, observedInterval,
            (isRecovery ? "recovery" : "following") as NSString))
        #endif

        withAnimation(animation) { scrollPosition.scrollTo(y: offset) }
    }

    /// Script tokens currently on screen, derived from the measured block geometry and the
    /// scroll view's own `visibleRect` — the region the reader chose by dragging.
    ///
    /// A block counts as visible when its content rect intersects the visible rect at all, so a
    /// partially-shown sentence still counts: the reader can read from it.
    /// Returns `nil` when the layout has not been measured, which leaves the resumption rule
    /// unarmed. **Never substitutes the whole script for a measured region** — doing so made the
    /// in-region check vacuous and allowed a resumption on an unmeasured layout.
    func visibleTokenRange() -> Range<Int>? {
        let sentences = viewModel.scriptIndex.sentences
        guard !sentences.isEmpty, visibleRect.height > 0 else { return nil }
        // At least one block must have been measured; without heights every block's rect is a
        // zero-height sliver at its computed top and the intersection test means nothing.
        guard blockHeights.values.contains(where: { $0 > 0 }) else { return nil }

        var lower: Int?
        var upper: Int?
        for (index, sentence) in sentences.enumerated() {
            guard let height = blockHeights[index], height > 0 else { continue }
            let top = contentOffset(ofBlock: index)
            let bottom = top + height
            guard bottom >= visibleRect.minY, top <= visibleRect.maxY else { continue }
            if lower == nil { lower = sentence.tokenStart }
            upper = sentence.tokenEnd
        }
        guard let lower, let upper, lower < upper else { return nil }
        return lower..<upper
    }

    #if DEBUG
    /// Wall-clock stamp for the ownership diagnostics, so a device capture can be read against the
    /// matcher's own timestamped lines.
    static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
    #endif

    /// Height reserved for the compact top control row, so the reading surface can start directly
    /// below it without guessing.
    private static let topControlRowHeight: CGFloat = Theme.minimumTouchTarget

    /// Below this, two targets are the same position and re-issuing one only restarts the ramp.
    private static let offsetEpsilon: CGFloat = 1.0
    #if DEBUG
    /// Read-only mirror so tests assert against the shipped value rather than a copy of it.
    static var offsetEpsilonForTests: CGFloat { offsetEpsilon }
    #endif

    /// Returns the reader to automatic following at the current confirmed position.
    private func resumeFollowing() {
        ownership.resumeAutomatically()
        lastTargetAt = nil
        lastAppliedOffset = nil
        #if DEBUG
        print(String(format: "[ScrollOwner] %@ resume -> automatic following (button override)", Self.stamp()))
        #endif
        guard let offset = readingOffset else { return }
        withAnimation(ScrollAnimator.recovery(reduceMotion: reduceMotion)) {
            scrollPosition.scrollTo(y: offset)
        }
    }

    /// Content-space y of a block's top: every earlier block's full height plus the stack spacing.
    /// Heights are measured on the block **including** its paragraph padding, so nothing is
    /// estimated — it is the geometry the text is actually laid out with.
    func contentOffset(ofBlock index: Int) -> CGFloat {
        Self.readingOffset(
            block: index, prefixHeight: 0, paragraphPadding: 0,
            blockHeights: blockHeights, blockSpacing: Self.blockSpacing,
            viewportHeight: 0, readingLine: 0
        )
    }

    /// The scroll offset that puts the line being read at `readingLineFraction` of the viewport.
    ///
    /// **This is why the round was needed.** The previous mechanism asked `scrollTo(id:anchor:)`
    /// for a position, and that API can only produce `blockTop = a·(V − H)` with `a ∈ [0, 1]` — a
    /// block's top can never rise above the viewport top. Holding the reading line fixed inside a
    /// long sentence needs exactly that, so the anchor saturated at 0 and the page stopped. The
    /// 2026-09-12 device log shows it five times (`anchor=0.000` at `progress` 0.27, 0.27, 0.42,
    /// 0.24, 0.30), each followed by silence until the next sentence began.
    ///
    /// An offset has no such band. `ScrollPosition.scrollTo(y:)` — verified against the installed
    /// iOS 26.5 SDK (`SwiftUICore.ScrollPosition.scrollTo(y: CGFloat)`) — accepts any content
    /// position, so the target moves continuously through a sentence of any length, and there is no
    /// switching-block jump because there is no block to switch to.
    ///
    /// Returns `nil` until geometry is known, so nothing is scrolled on a guess.
    var readingOffset: CGFloat? {
        guard viewportHeight > 0, !blockHeights.isEmpty else { return nil }
        let block = currentSentenceIndex
        guard blockHeights[block] != nil else { return nil }
        let isFirst = sentenceBlocks.first { $0.id == block }?.isFirstInParagraph == true
        // Only a measurement made for *this* block **and** this cursor position describes the line
        // being read. Anything else is the previous layout pass leaking through (see
        // `PrefixMeasurement`).
        guard prefixMeasurement.block == block, prefixMeasurement.token == viewModel.cursor.tokenIndex else { return nil }
        let withinBlock: CGFloat = prefixMeasurement.height
        return Self.readingOffset(
            block: block,
            prefixHeight: withinBlock,
            paragraphPadding: isFirst ? Self.paragraphSpacing : 0,
            blockHeights: blockHeights,
            blockSpacing: Self.blockSpacing,
            viewportHeight: viewportHeight,
            readingLine: Self.readingLineFraction
        )
    }

    /// Pure form of the same calculation, so it is unit-tested without a view.
    static func readingOffset(
        block: Int,
        prefixHeight: CGFloat,
        paragraphPadding: CGFloat,
        blockHeights: [Int: CGFloat],
        blockSpacing: CGFloat,
        viewportHeight: CGFloat,
        readingLine: CGFloat
    ) -> CGFloat {
        var top: CGFloat = 0
        if block > 0 {
            for earlier in 0..<block {
                top += (blockHeights[earlier] ?? 0) + blockSpacing
            }
        }
        let target = top + paragraphPadding + prefixHeight - readingLine * viewportHeight
        return max(0, target)
    }

    private var currentSentenceIndex: Int {
        ScriptStyling.currentSentenceIndex(scriptIndex: viewModel.scriptIndex, cursor: viewModel.cursor)
    }

    /// Where the line being read sits in the viewport: near the top, just under the safe area.
    ///
    /// Was 0.28, which left roughly a quarter of the screen empty above the reading line — the
    /// "excessive empty space above" in the 2026-09-11 report and visible in the screenshots.
    ///
    /// The *how* is no longer a fixed anchor: see
    /// `anchor(forProgress:blockHeight:viewportHeight:readingLine:)`, which solves for the unit
    /// point that actually places the reading position here, given the measured block and viewport
    /// heights. The earlier note here — that a single `UnitPoint` makes this impossible — was only
    /// true of sweeping the fraction blind; with `H` and `V` measured it is a two-line calculation.
    private static let readingLineFraction: CGFloat = 0.12

    /// `LazyVStack` spacing, needed by `scrollTarget` to walk from one block's top to the next.
    private static let blockSpacing: CGFloat = 4

    /// Extra top padding on the first sentence of each paragraph.
    private static let paragraphSpacing: CGFloat = 16

    // `isListeningPulseTarget` removed (M5.3.1). It dimmed the **whole current sentence** to 0.55
    // opacity whenever `cursor.state == .holding`, selecting the block purely by
    // `currentSentenceIndex` — i.e. by cursor position. On the 2026-09-11 device session the cursor
    // held for minutes at a time (tokens 8, 14, 30, 46, 47, 107, 118, 119, 139), and ¶1's second
    // sentence spans tokens 3-35, so the reader saw most of an unread paragraph faded out. That is
    // the second greying path, independent of `spokenTokenIndices`, and it is what the screenshots
    // show. The presentation contract forbids cursor position determining whether text looks
    // spoken, so the pulse is gone rather than merely retuned.

    // MARK: Bottom bar (§12.4: single bar, auto-hides after 3s, bottom 40%, one-handed)

    private var bottomBar: some View {
        HStack(spacing: 28) {
            // Restart — icon only, labelled for VoiceOver.
            compactControl(systemImage: "arrow.counterclockwise", label: "Restart") {
                revealControls()
                ownership.resumeAutomatically()
                lastTargetAt = nil
                lastAppliedOffset = nil
                scrollPosition.scrollTo(y: 0)
                viewModel.start()
            }

            // Session pause/resume — the prominent control. This is the *session* transport; it is
            // unrelated to the removed "[pause]" script-marker insertion (M5.10).
            Button {
                revealControls()
                if viewModel.isPausedByInterruption || viewModel.isManuallyPaused {
                    viewModel.resume()
                } else if viewModel.isRunning {
                    viewModel.pause()
                } else {
                    viewModel.start()
                }
            } label: {
                Image(systemName: transportSymbol)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.Color.onDark)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(Theme.Color.action))
            }
            .accessibilityLabel(primaryButtonLabel)

            // Additional settings, including exit.
            Menu {
                Button("Exit reading", systemImage: "xmark") {
                    viewModel.stop()
                    dismiss()
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.Color.ink)
                    .frame(width: Theme.minimumTouchTarget, height: Theme.minimumTouchTarget)
            }
            .accessibilityLabel("More options")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Theme.Color.hairline, lineWidth: 0.5))
        .padding(.bottom, 24)
    }

    /// An icon-only control at the minimum touch target with an accessible label.
    private func compactControl(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.Color.ink)
                .frame(width: Theme.minimumTouchTarget, height: Theme.minimumTouchTarget)
        }
        .accessibilityLabel(label)
    }

    private var transportSymbol: String {
        if viewModel.isPausedByInterruption || viewModel.isManuallyPaused { return "play.fill" }
        return viewModel.isRunning ? "pause.fill" : "play.fill"
    }

    /// Compact close control and status, pinned near the top so the reading surface starts high.
    private var topBar: some View {
        HStack {
            Button {
                viewModel.stop()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.Color.ink)
                    .frame(width: Theme.minimumTouchTarget, height: Theme.minimumTouchTarget)
                    .background(Circle().fill(.regularMaterial))
            }
            .accessibilityLabel("Close")

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(viewModel.isRunning ? Theme.Color.action : Theme.Color.secondary)
                    .frame(width: 8, height: 8)
                Text(statusLabel)
                    .font(.footnote)
                    .foregroundStyle(Theme.Color.secondary)
            }
            .accessibilityElement(children: .combine)

            Spacer()

            // Balances the close button so the status sits centred.
            Color.clear.frame(width: Theme.minimumTouchTarget, height: Theme.minimumTouchTarget)
        }
        .padding(.horizontal, 16)
    }

    private var statusLabel: String {
        if viewModel.isPausedByInterruption || viewModel.isManuallyPaused { return "Paused" }
        if ownership.isManuallyDetached { return "Browsing" }
        return viewModel.isRunning ? "Following your voice" : "Ready"
    }

    private var primaryButtonLabel: String {
        if viewModel.isPausedByInterruption || viewModel.isManuallyPaused { return "Resume" }
        return viewModel.isRunning ? "Pause" : "Start"
    }

    private func revealControls() {
        showControls = true
        scheduleAutoHide()
    }

    private func scheduleAutoHide() {
        hideControlsTask?.cancel()
        hideControlsTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            showControls = false
        }
    }

    // MARK: End of session (§12.4: in-place, not a modal)

    private var summaryView: some View {
        VStack(spacing: 20) {
            Spacer()
            Text("That's the script.")
                .font(Typography.display(28))
                .foregroundStyle(palette.ink)
            if let duration = sessionDurationText {
                Text(duration)
                    .font(Typography.body(16))
                    .foregroundStyle(palette.spoken)
            }
            Text("Shot something great? Tag #Prompter")
                .font(Typography.body(13))
                .foregroundStyle(palette.spoken)
            Spacer()
            Button("Done") {
                viewModel.stop()
                dismiss()
            }
            .buttonStyle(.prompterPrimary)
            .padding(.horizontal, 40)
            .padding(.bottom, 40)
        }
    }

    private var sessionDurationText: String? {
        guard let startedAt = viewModel.sessionStartedAt else { return nil }
        let seconds = Int(Date().timeIntervalSince(startedAt))
        let minutes = seconds / 60
        let remainder = seconds % 60
        return String(format: "%d:%02d", minutes, remainder)
    }
}


/// Per-sentence rendered heights, collected so the scroll anchor can be computed from real
/// geometry rather than guessed (see `PromptScreen.anchor(forProgress:blockHeight:viewportHeight:readingLine:)`).
/// Rendered height of the current sentence's text up to the word being read — the reading line's
/// real vertical offset inside its block.
/// A prefix height together with **exactly which block and cursor position it describes**.
///
/// Tagging by block alone was not enough: at a block boundary the overlay re-renders with the new
/// `block.id` while the `Text` still holds the previous prefix for one layout pass, so a stale
/// height arrives labelled with the new block. The 2026-09-11 device log shows the result as two
/// targets for one token — `token=155 … targetY=1693.0` then `1707.0`, and `token=36 … prefixH=365`
/// then `prefixH=14`. Carrying the token as well makes a stale measurement identifiable and
/// discardable.
struct PrefixMeasurement: Equatable {
    let block: Int
    let token: Int
    let height: CGFloat
}

private struct PrefixHeightPreference: PreferenceKey {
    static let defaultValue = PrefixMeasurement(block: -1, token: -1, height: 0)
    static func reduce(value: inout PrefixMeasurement, nextValue: () -> PrefixMeasurement) {
        let next = nextValue()
        if next.height > 0 { value = next }
    }
}

private struct BlockHeightPreference: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}
