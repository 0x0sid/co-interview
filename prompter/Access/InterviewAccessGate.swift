import Foundation

/// What a Live interview asks before spending paid AI: may it, and if not, show the paywall.
/// Nil in Demo and in tests, where everything is allowed.
@MainActor
protocol InterviewAccessGate: AnyObject {
    var allowsPaidRequests: Bool { get }
    /// May one more answer be accepted, with `pending` free answers already queued or running?
    func allowsNewAnswer(pending: Int) -> Bool
    /// The user asked for the paywall (Upgrade, Subscribe). Opens it whenever asked — but never a
    /// second sheet while one is showing.
    func requestPaywall(_ trigger: PaywallTrigger)
    /// A new question was blocked because the free answers are used. Opens the paywall by itself only
    /// the first time ever; after that the blocked attempt gets the inline Upgrade, not a modal.
    func requestAutomaticPaywall(_ trigger: PaywallTrigger) -> AutomaticPaywallOutcome
    /// An answer finished. `counted`: non-empty and not only a clarification or context request.
    func noteAnswerCompleted(counted: Bool)
}

extension AccessController: InterviewAccessGate {}
