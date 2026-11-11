import Foundation

/// Explicit availability for every monitored metric. Unavailable metrics are
/// never rendered as 0: consumers must branch on this first.
enum MetricAvailability: Equatable, Sendable {
    case available
    case unavailable(reason: String)
    case permissionRestricted
    case stale(reason: String)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    var displayText: String? {
        switch self {
        case .available:
            return nil
        case .unavailable(let reason):
            return reason
        case .permissionRestricted:
            return "Permission required"
        case .stale(let reason):
            return reason
        }
    }
}
