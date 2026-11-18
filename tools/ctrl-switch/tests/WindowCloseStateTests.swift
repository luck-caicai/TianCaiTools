import ApplicationServices

enum WindowCloseStateTests {
    static func run(_ check: (Bool, String) -> Void) {
        for reply: AXError in [.cannotComplete, .failure, .invalidUIElement] {
            let result = WindowCloseResult.fromActionReply(reply)
            check(result == .unconfirmed, "ambiguous close reply is never declared successful or failed")
            check(result.mayHaveBeenDelivered && !result.shouldSignalFailure,
                  "save-dialog timeout still checks native confirmation without an error beep")
        }
        let accepted = WindowCloseResult.fromActionReply(.success)
        check(accepted == .requested && accepted.mayHaveBeenDelivered && !accepted.shouldSignalFailure,
              "accepted close still follows actual window state")
        for reply: AXError in [.actionUnsupported, .notImplemented] {
            let result = WindowCloseResult.fromActionReply(reply)
            check(result == .unavailable && !result.mayHaveBeenDelivered && result.shouldSignalFailure,
                  "unsupported close action is not treated as a delivered request")
        }
        let denied = WindowCloseResult.fromActionReply(.apiDisabled)
        check(denied == .failed && denied.shouldSignalFailure && !denied.mayHaveBeenDelivered,
              "revoked accessibility access remains an explicit failure")
        check(!WindowCloseResult.stale.shouldSignalFailure && !WindowCloseResult.stale.mayHaveBeenDelivered,
              "already-gone window has no close retry or unnecessary beep")
    }
}
