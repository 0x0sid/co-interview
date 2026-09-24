#if DEBUG
import SwiftUI
import UniformTypeIdentifiers

/// The diagnostics controls: one `Section`, shown in two places.
///
/// It lives in the existing Debug surface (`CopilotDebugScreen`), and the **same section** is what
/// `DiagnosticsSheet` presents from the interview's ••• menu. One definition, so the controls cannot
/// drift apart, and so switching capture on mid-session is the same switch as switching it on
/// beforehand.
struct DiagnosticsDebugSection: View {
    // `@Bindable` is the idiom for binding to a shared `@Observable` someone else owns; `@State`
    // would imply this view owns the singleton's lifetime, which it does not.
    @Bindable private var diagnostics = GenerateDiagnostics.shared
    @State private var share: SharePayload?
    @State private var backend: CopilotBackendConfiguration?
    @State private var backendChecked = false

    private let info = Bundle.main.infoDictionary ?? [:]
    private let configuration = ProviderConfiguration.resolve()

    /// What is actually running, so a device test can be checked before it starts: the commit and
    /// checkout this build came from, and the backend it talks to with that backend's decision mode.
    private var buildSection: some View {
        Section("Build & backend") {
            LabeledContent("App commit", value: info["GitCommitHash"] as? String ?? "unknown")
            LabeledContent("Built", value: info["BuildDate"] as? String ?? "unknown")
            LabeledContent("From checkout", value: info["BuildSource"] as? String ?? "unknown")
            LabeledContent("Backend", value: endpoint)
            LabeledContent("Jev decisions", value: jevSummary)
        }
    }

    private var endpoint: String {
        switch configuration.availability {
        case .backend(let url): "\(url.absoluteString) (\(configuration.source.rawValue))"
        case .developmentFake: "development fake"
        case .unavailable(let reason): "none — \(reason)"
        }
    }

    private var jevSummary: String {
        guard backendChecked else { return "checking…" }
        guard let decisions = backend?.decisions else { return backend == nil ? "backend not reachable" : "not reported" }
        let optIn = decisions.session_opt_in == true ? "per-session opt-in allowed" : "no per-session opt-in"
        return "\(decisions.mode) · \(optIn)"
    }

    var body: some View {
        buildSection
            .task {
                backend = await configuration.makeProvider().configuration()
                backendChecked = true
            }
        Section("Generate diagnostics") {
            Toggle("Capture test content", isOn: $diagnostics.isContentCaptureEnabled)
            Text("Off by default. When on, reports also include **what was said in the interview and the answers written for it** — the transcript, the exact snapshot, the request, the provider messages and the answer. Credentials and image data are never included.\n\nIt applies to taps made **from now on** in this session, and returns to off when the next session starts.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Toggle("Apply Jev decisions (this session)", isOn: $diagnostics.isDecisionApplyRequested)
            Text("Asks the backend to let accepted decisions shape this session's requests. It has effect only if the backend allows per-session opt-in; otherwise decisions are recorded, not used. Returns to off when the next session starts.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            LabeledContent("Session", value: diagnostics.sessionID.uuidString.prefix(8).description)
            LabeledContent("Traces", value: "\(diagnostics.traces.count) of \(GenerateDiagnostics.maximumTraces)")
            LabeledContent("Captured text", value: diagnostics.hasCapturedContent ? "present" : "none")
            if let failure = diagnostics.recorderFailure {
                Text("Recorder failure: \(failure)").font(.footnote).foregroundStyle(.red)
            }

            Button("Export last request") {
                guard let trace = diagnostics.lastTrace else { return }
                Task {
                    let decisions = await diagnostics.fetchDecisionRecords()
                    share = payload(traces: [trace], title: "Neverblank — last request", decisions: decisions)
                }
            }
            .disabled(diagnostics.lastTrace == nil)

            // Enabled without any Generate trace too: the backend's decision comparisons exist for
            // every classification, whether or not anything was generated.
            Button("Export test session") {
                Task {
                    let decisions = await diagnostics.fetchDecisionRecords()
                    share = payload(traces: diagnostics.traces, title: "Neverblank — test session", decisions: decisions)
                }
            }
            .disabled(diagnostics.traces.isEmpty && diagnostics.decisionRecordsFetcher == nil)

            Button("Clear diagnostics", role: .destructive) { diagnostics.clear() }
                .disabled(diagnostics.traces.isEmpty)
        }
        .sheet(item: $share) { payload in
            ShareSheet(items: payload.urls)
        }
    }

    /// Writes both formats to temporary files and hands them to the share sheet.
    ///
    /// Files rather than strings so the share sheet offers Files, Mail and AirDrop with real
    /// attachments. They live in the temporary directory, which the system reclaims; nothing is
    /// uploaded, and nothing leaves the phone unless the person picks a destination.
    private func payload(traces: [GenerateTrace], title: String, decisions: String?) -> SharePayload {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let base = FileManager.default.temporaryDirectory
        let markdownURL = base.appendingPathComponent("co-interview-diagnostics-\(stamp).md")
        let jsonURL = base.appendingPathComponent("co-interview-diagnostics-\(stamp).json")
        let markdown = DiagnosticsExport.markdown(session: diagnostics, traces: traces, title: title, decisions: decisions)
        let json = DiagnosticsExport.json(session: diagnostics, traces: traces, decisions: decisions)
        // A failed export must not take the app with it: this is a diagnostic, not the interview.
        try? markdown.data(using: .utf8)?.write(to: markdownURL)
        try? json.data(using: .utf8)?.write(to: jsonURL)
        return SharePayload(urls: [markdownURL, jsonURL])
    }
}

/// The diagnostics controls, presented from inside a live interview.
///
/// This exists because capture is per-session and resets when a session starts: without a way in
/// from the interview there was no moment at which it could be switched on for the session you are
/// actually in. Start the interview, open this, switch capture on, carry on — the session is not
/// interrupted and nothing is restarted.
struct DiagnosticsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                DiagnosticsDebugSection()
            }
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct SharePayload: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
