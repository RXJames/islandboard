import Foundation

struct ProcessEntryStats: Identifiable, Equatable, Sendable {
    var pid: Int32
    var name: String
    var user: String?
    var uid: UInt32?
    /// 100 % = one logical core, matching `ps`/Activity Monitor.
    /// `nil` on warm-up or when the process is permission-restricted.
    var cpuPercent: Double?
    var memoryBytes: UInt64?
    var state: String
    /// True when task/rusage data could not be read; name/user/state may still
    /// be available through the short BSD record.
    var restricted: Bool

    var id: Int32 { pid }
}

struct ProcessStatsSnapshot: Equatable, Sendable {
    var availability: MetricAvailability
    var sampledAt: Date
    var total: Int
    var restricted: Int
    var items: [ProcessEntryStats]
}

enum ProcessCPUCalculator {
    /// `cpuTimeNs` is converted from mach absolute ticks before this call.
    static func percent(cpuTimeNs: Double, wallTime: TimeInterval) -> Double? {
        guard wallTime > 0, wallTime.isFinite, cpuTimeNs > 0 else { return nil }
        let value = cpuTimeNs / (wallTime * 1_000_000_000) * 100
        return value.isFinite ? max(0, value) : nil
    }

    static func stateName(_ status: UInt32) -> String {
        switch status {
        case 1: return "idle"
        case 2: return "running"
        case 3: return "sleeping"
        case 4: return "stopped"
        case 5: return "zombie"
        default: return "unknown"
        }
    }
}
