import Foundation

/// What a Live interview asks before spending paid AI: may it, and if not, show the paywall.
/// Nil in Demo and in tests, where everything is allowed.
@MainActor
protocol InterviewAccessGate: AnyObject {
    var allowsPaidRequests: Bool { get }
    func requestPaywall(_ trigger: PaywallTrigger)
}

extension AccessController: InterviewAccessGate {}
