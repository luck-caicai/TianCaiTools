import ApplicationServices

enum WindowCloseResult: String {
    case requested, unconfirmed, unavailable, stale, failed

    static func fromActionReply(_ error: AXError) -> WindowCloseResult {
        switch error {
        case .success: return .requested
        // A save/close flow can outlive the AX reply timeout after delivery.
        case .cannotComplete, .failure, .invalidUIElement: return .unconfirmed
        case .actionUnsupported, .notImplemented: return .unavailable
        default: return .failed
        }
    }

    var mayHaveBeenDelivered: Bool { self == .requested || self == .unconfirmed }
    var shouldSignalFailure: Bool { self == .unavailable || self == .failed }
}
