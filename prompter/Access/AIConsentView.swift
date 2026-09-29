import SwiftUI

/// Consent to AI processing, asked once before the first Live interview (App Review 5.1.2(i)).
///
/// It says plainly what leaves the iPhone and where it goes. Nothing is sent before it is accepted:
/// the start screen opens Live only after `AIConsent.isGiven`.
enum AIConsent {
    static let defaultsKey = "NeverblankAIConsentAt"

    static func isGiven(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) != nil
    }

    static func record(_ defaults: UserDefaults = .standard, at date: Date = Date()) {
        defaults.set(date, forKey: defaultsKey)
    }
}

struct AIConsentView: View {
    let onAgree: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Before your first Live interview")
                    .font(Typography.display(24))
                    .foregroundStyle(Theme.Color.ink)
                point("waveform", "Speech is turned into text on your iPhone. Audio is never recorded or uploaded.")
                point("arrow.up.doc", "To spot questions and write answers, Neverblank sends the transcript text, your note and excerpts of files you attach to its AI service, which uses third-party AI model providers to process them.")
                point("lock", "It is used only to answer during your interview — never for advertising, and never sold.")
                point("person.2", "Let the people you are speaking with know that you use an assistant, where that is expected or required.")
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(FreeAnswersRecord.limit) free interview answers")
                        .font(Typography.body(14, weight: .semibold))
                        .foregroundStyle(Theme.Color.ink)
                    Text(AccessCopy.freeAnswersDisclosure)
                        .font(Typography.body(13))
                        .foregroundStyle(Theme.Color.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Color.card, in: RoundedRectangle(cornerRadius: 12))
                if let privacy = LegalLinks.privacy {
                    Link("Privacy Policy", destination: privacy)
                        .font(Typography.body(13, weight: .medium))
                }
                Button("Agree and continue", action: onAgree)
                    .buttonStyle(.prompterPrimary)
                    .accessibilityIdentifier("ai-consent-agree")
                Button("Not now", action: onCancel)
                    .font(Typography.body(14, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
            .padding(20)
        }
        .background(Theme.Color.paper)
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(Theme.Color.action)
                .frame(width: 22)
            Text(text)
                .font(Typography.body(14))
                .foregroundStyle(Theme.Color.ink)
        }
    }
}

/// Wording used in more than one place, so the free answers are described the same way everywhere.
enum AccessCopy {
    static let freeAnswersDisclosure = "Every new install includes \(FreeAnswersRecord.limit) free interview answers in total — one per question you ask; regenerating an answer or a follow-up on it is free. They don't renew, this isn't an App Store trial, and nothing is charged. After that, listening and the transcript keep working on your iPhone; more answers need Neverblank Pro."

    /// The free-answer state in one line, by how many are left.
    static func freeAnswersStatus(remaining: Int, limit: Int = FreeAnswersRecord.limit) -> String {
        switch remaining {
        case let count where count >= limit: "\(limit) free interview answers included."
        case 1: "1 free interview answer remaining."
        case let count where count > 1: "\(count) free interview answers remaining."
        default: "Your \(limit) free interview answers are used. Upgrade to Pro for more."
        }
    }

    /// "2 free interview answers remaining" — without the full stop, for compact places.
    static func freeAnswersRemaining(_ count: Int) -> String {
        count == 1 ? "1 free interview answer remaining" : "\(count) free interview answers remaining"
    }

    /// The quiet locked state once the free answers are used.
    static func freeAnswersUsed(limit: Int) -> String { "\(limit) free answers used. The transcript keeps going." }
}
