import Foundation

/// What a Live interview asks before spending paid AI: may it, and if not, show the paywall.
/// Nil in Demo and in tests, where everything is allowed.
@MainActor
protocol InterviewAccessGate: AnyObject {
    var allowsPaidRequests: Bool { get }
    /// May one more answer be accepted, with `pending` free answers already queued or running?
    func allowsNewAnswer(pending: Int) -> Bool
    func requestPaywall(_ trigger: PaywallTrigger)
    /// An answer finished. `counted`: non-empty and not only a clarification or context request.
    func noteAnswerCompleted(counted: Bool)
}

extension AccessController: InterviewAccessGate {}
