import SwiftUI

/// The v2.5 interview screen.
///
/// **This build is UI and demo data.** There is no provider, no backend and no microphone behind it:
/// `DemoInterviewFeed` plays a scripted interview so the screen can be built and judged as a screen.
/// Live mode is reachable but says plainly that it needs a service this build has no connection to —
/// it never quietly falls back to the demo script.
///
/// The demo is also never allowed to look like listening: the header mark shows "Demo playback", not
/// a live recording waveform, and the badge above the toolbar says so in words.
struct InterviewScreen: View {
    @State private var model: InterviewScreenModel
    @Environment(\.dismiss) private var dismiss
    let title: String
    /// What Live can do this session.
    ///
    /// **Held in state, not fixed at presentation.** It used to be a snapshot taken once on the
    /// start screen, so a single slow probe disabled Generate for the whole session while listening
    /// and detection carried on working — which read as "the backend is unreachable" even though the
    /// phone was talking to it successfully.
    @State private var readiness: LiveReadiness
    /// Re-runs the readiness check. Nil in Demo, which has nothing to check.
    private let recheckReadiness: (() async -> LiveReadiness)?
    @State private var isRechecking = false

    init(
        mode: InterviewMode,
        title: String = "Technical interview",
        feed: (any InterviewFeed)? = nil,
        readiness: LiveReadiness = LiveReadiness(),
        recheckReadiness: (() async -> LiveReadiness)? = nil
    ) {
        self.title = title
        _readiness = State(wrappedValue: readiness)
        self.recheckReadiness = recheckReadiness
        _model = State(wrappedValue: InterviewScreenModel(mode: mode, feed: feed ?? DemoInterviewFeed()))
    }

    /// Checks again, on demand. Used by Retry and after a generation fails, because the most common
    /// cause of a stale blocker is a backend that was simply slow to wake up.
    private func recheck() async {
        guard let recheckReadiness, !isRechecking else { return }
        isRechecking = true
        readiness = await recheckReadiness()
        model.applyBackendCapability(acceptsImages: readiness.answerAcceptsImages)
        isRechecking = false
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            InterviewTheme.Color.background.ignoresSafeArea()

            VStack(spacing: 14) {
                InterviewHeaderView(
                    title: title,
                    recording: model.recording,
                    isSimulatedSource: model.mode == .demo,
                    listeningLabel: model.mode == .live ? model.listeningState?.label : nil,
                    canGoToPrevious: model.canGoToPrevious,
                    canGoToNext: model.canGoToNext,
                    onBack: { model.stop(); dismiss() },
                    onPrevious: { model.goToPrevious() },
                    onNext: { model.goToNext() },
                    onSettings: {}
                )

                VStack(spacing: 12) {
                    TranscriptStripView(
                        lines: model.transcript,
                        isExpanded: $model.isTranscriptExpanded,
                        isContextOpen: $model.isContextPanelOpen,
                        context: model.context,
                        onSelectQuestion: { model.select(questionID: $0) },
                        onAddImage: { _ = model.attachImage($0.data) },
                        onRemoveImage: { model.removeAttachment(id: $0) },
                        onNoteChanged: { model.context.note = $0; model.syncSessionNote() },
                        limitationMessage: model.contextLimitationMessage,
                        attachmentStates: model.attachmentLabels
                    )
                    pager
                }
                .padding(.horizontal, 18)
            }

            bottomFade
            floatingControls
        }
        .background(InterviewTheme.Color.background)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            model.start()
            // Ask the backend what the configured answer model can actually read, so the Context
            // panel tells the truth about attachments instead of guessing.
            model.applyBackendCapability(acceptsImages: readiness.answerAcceptsImages)
        }
        .onDisappear { model.stop() }
        // A failed generation is the strongest signal that readiness is stale — re-check once so the
        // next attempt reports the real cause instead of repeating a snapshot taken minutes ago.
        .onChange(of: model.generationFailure) { _, failure in
            guard failure != nil else { return }
            Task { await recheck() }
        }
        .sheet(isPresented: $model.isFollowUpsSheetPresented) {
            if let question = model.currentQuestion {
                FollowUpsSheet(question: question)
            }
        }
    }

    // MARK: Pages

    /// Swipe left and right between questions. The pages are the model's, so the header chevrons and
    /// the swipe are two ways to move the same index and cannot disagree.
    @ViewBuilder
    private var pager: some View {
        if model.questions.isEmpty {
            waitingState
        } else {
            TabView(selection: Binding(
                get: { model.currentIndex },
                set: { model.select(index: $0) }
            )) {
                ForEach(Array(model.questions.enumerated()), id: \.element.id) { index, question in
                    AnswerPageView(
                        question: question,
                        counterText: model.counterText(forPage: index),
                        alignment: model.alignment(for: question),
                        isAutoScrolling: model.isAutoScrolling(question),
                        isGenerating: model.isGenerating(questionID: question.id),
                        failureMessage: index == model.currentIndex ? model.generationFailure : nil,
                        onGenerate: { model.generate(for: question) },
                        onFollowUps: { model.isFollowUpsSheetPresented = true },
                        onBeginManualScroll: { model.beginManualScroll(on: question) },
                        onEndManualScroll: { model.endManualScroll(on: question, visibleTokens: $0) },
                        onResumeFollowing: { model.resumeFollowing(on: question) }
                    )
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
    }

    /// Before the first question there is nothing to show, and pretending otherwise would be worse
    /// than an honest line of text.
    private var waitingState: some View {
        VStack(spacing: 8) {
            Text(model.mode == .demo ? "Playing the demo interview…" : "Listening…")
                .font(InterviewTheme.Font.ui(15, weight: .medium, relativeTo: .subheadline))
                .foregroundStyle(InterviewTheme.Color.muted)
            Text("Questions appear here as they are detected. Answers are written only when you tap Generate.")
                .font(InterviewTheme.Font.ui(13, relativeTo: .footnote))
                .foregroundStyle(InterviewTheme.Color.muted.opacity(0.8))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
    }

    // MARK: Bottom

    private var bottomFade: some View {
        LinearGradient(
            colors: [InterviewTheme.Color.background.opacity(0), InterviewTheme.Color.background],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: InterviewTheme.Metric.bottomFade)
        .frame(maxWidth: .infinity, alignment: .bottom)
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    private var floatingControls: some View {
        VStack(spacing: 10) {
            if let number = model.readyQuestionNumber {
                ReadyChipView(questionNumber: number) { model.followReadyChip() }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if model.mode == .demo {
                demoBadge
            } else if !readiness.canGenerate {
                listenOnlyBadge
            }
            ActionPillView(
                recording: model.recording,
                isGenerating: model.isGeneratingForTarget,
                canGenerate: model.mode == .demo || readiness.canGenerate,
                onToggleRecording: { model.toggleRecordingPause() },
                onGenerate: { model.generate() },
                menu: { moreMenu }
            )
        }
        .padding(.bottom, 26)
        .animation(.easeInOut(duration: 0.2), value: model.readyQuestionNumber)
    }

    /// Says what this is, always, while the demo is running — including whether the fading text is a
    /// simulation rather than someone actually reading. The microphone is never open in demo mode
    /// and the badge is what keeps that from being ambiguous.
    private var demoBadge: some View {
        Text(badgeText)
            .font(InterviewTheme.Font.ui(11, weight: .semibold, relativeTo: .caption2))
            .foregroundStyle(InterviewTheme.Color.demoBadge)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(InterviewTheme.Color.surface, in: Capsule())
            .overlay(Capsule().stroke(InterviewTheme.Color.demoBadge.opacity(0.35), lineWidth: 1))
    }

    private var badgeText: String {
        if model.isSimulatedReadingRunning { return "Demo · simulated reading" }
        if model.recording == .live { return "Demo · scripted playback, microphone off" }
        return "Demo · paused"
    }

    /// The honest half-working state: speech is being transcribed and questions detected, but no
    /// answer can be generated. Saying which half works is more useful than refusing to start.
    private var listenOnlyBadge: some View {
        Button {
            Task { await recheck() }
        } label: {
            HStack(spacing: 6) {
                Text(isRechecking ? "Checking…" : (readiness.blockers.first?.message ?? "Answers unavailable"))
                    .font(InterviewTheme.Font.ui(11, weight: .semibold, relativeTo: .caption2))
                    .multilineTextAlignment(.center)
                // Retry lives on the badge that states the problem, which is where someone looks
                // for it — no new control and no change to the layout.
                if readiness.isRetryable, !isRechecking {
                    Text("Retry")
                        .font(InterviewTheme.Font.ui(11, weight: .bold, relativeTo: .caption2))
                        .underline()
                }
            }
            .foregroundStyle(InterviewTheme.Color.demoBadge)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(InterviewTheme.Color.surface, in: Capsule())
            .overlay(Capsule().stroke(InterviewTheme.Color.demoBadge.opacity(0.35), lineWidth: 1))
            .padding(.horizontal, 24)
        }
        .buttonStyle(.plain)
        .disabled(recheckReadiness == nil)
        .accessibilityLabel(readiness.blockers.first?.message ?? "Answers unavailable")
        .accessibilityHint(readiness.isRetryable ? "Double tap to check the connection again" : "")
    }

    @ViewBuilder
    private var moreMenu: some View {
        Button {
            model.regenerate()
        } label: {
            Label("Regenerate answer", systemImage: "arrow.clockwise")
        }
        .disabled(model.currentQuestion?.selectedAnswer == nil)

        if model.mode == .demo {
            Toggle(isOn: Binding(
                get: { model.isSimulatedReadingEnabled },
                set: { model.isSimulatedReadingEnabled = $0 }
            )) {
                Label("Simulated reading", systemImage: "text.book.closed")
            }
        }

        if model.mode == .live, recheckReadiness != nil {
            Button {
                Task { await recheck() }
            } label: {
                Label("Check connection", systemImage: "arrow.clockwise.circle")
            }
        }

        Button {
            model.isTranscriptExpanded.toggle()
        } label: {
            Label(model.isTranscriptExpanded ? "Collapse transcript" : "Expand transcript", systemImage: "text.alignleft")
        }
    }
}

/// What Live shows in this build. It is a state, not a placeholder screen: the copilot is not
/// connected to any service here, and saying so is the honest thing to put on screen.
struct InterviewLiveUnavailableView: View {
    var readiness = LiveReadiness()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            WaveformShape(levels: [0.25, 0.4, 0.55, 0.4, 0.25])
                .fill(InterviewTheme.Color.muted)
                .frame(width: 40, height: 28)
            Text("Live can't start")
                .font(InterviewTheme.Font.ui(18, weight: .semibold, relativeTo: .title3))
                .foregroundStyle(InterviewTheme.Color.ink)
            // Every blocker, in the words that say what to fix. Listening blockers come first
            // because they are the ones that stop the session existing at all.
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(readiness.blockers.enumerated()), id: \.offset) { _, blocker in
                    Text("• \(blocker.message)")
                        .font(InterviewTheme.Font.ui(14, relativeTo: .subheadline))
                        .foregroundStyle(InterviewTheme.Color.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if readiness.blockers.isEmpty {
                    Text("Live needs microphone and speech-recognition access.")
                        .font(InterviewTheme.Font.ui(14, relativeTo: .subheadline))
                        .foregroundStyle(InterviewTheme.Color.muted)
                }
            }
            Button("Close") { dismiss() }
                .font(InterviewTheme.Font.ui(15, weight: .semibold, relativeTo: .subheadline))
                .foregroundStyle(InterviewTheme.Color.primary)
                .padding(.top, 6)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(InterviewTheme.Color.background.ignoresSafeArea())
    }
}
