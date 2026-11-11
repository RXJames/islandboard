import Foundation

struct CPUStats: Equatable, Sendable {
    var availability: MetricAvailability
    var sampledAt: Date
    /// True until two tick snapshots exist; consumers show a placeholder
    /// instead of a misleading 0 %.
    var isWarmingUp: Bool
    var totalUsage: Double
    var userPercent: Double
    var systemPercent: Double
    var idlePercent: Double
    var perCore: [Double]
    var loadAverage: LoadAverage?
    var uptime: TimeInterval?
    var history: [Double]
}

/// Pure delta math, kept separate from Mach calls so it is unit-testable.
enum CPUUsageCalculator {
    struct CoreTicks: Equatable, Sendable {
        var user: UInt32
        var system: UInt32
        var idle: UInt32
        var nice: UInt32
    }

    struct Breakdown: Equatable, Sendable {
        var usage: Double
        var user: Double
        var system: Double
        var idle: Double
        var perCore: [Double]

        static func zero(coreCount: Int) -> Breakdown {
            Breakdown(usage: 0, user: 0, system: 0, idle: 0, perCore: Array(repeating: 0, count: coreCount))
        }
    }

    /// `nil` means "no previous snapshot" (warm-up) or a topology change.
    static func calculate(previous: [CoreTicks]?, current: [CoreTicks]) -> Breakdown? {
        guard let previous, !current.isEmpty, previous.count == current.count else {
            return nil
        }

        var userDelta: UInt64 = 0
        var systemDelta: UInt64 = 0
        var idleDelta: UInt64 = 0
        var niceDelta: UInt64 = 0
        var perCore: [Double] = []
        perCore.reserveCapacity(current.count)

        for (before, now) in zip(previous, current) {
            // Ticks are 32-bit and wrap on long uptimes; wrapping subtraction
            // yields the true delta.
            let user = UInt64(now.user &- before.user)
            let system = UInt64(now.system &- before.system)
            let idle = UInt64(now.idle &- before.idle)
            let nice = UInt64(now.nice &- before.nice)

            userDelta += user
            systemDelta += system
            idleDelta += idle
            niceDelta += nice

            let total = user + system + idle + nice
            if total == 0 {
                perCore.append(0)
            } else {
                perCore.append(clamp(Double(user + nice + system) / Double(total) * 100))
            }
        }

        let total = userDelta + systemDelta + idleDelta + niceDelta
        guard total > 0 else { return nil }

        let user = Double(userDelta + niceDelta) / Double(total) * 100
        let system = Double(systemDelta) / Double(total) * 100
        let idle = Double(idleDelta) / Double(total) * 100
        let usage = clamp(user + system)
        return Breakdown(usage: usage, user: clamp(user), system: clamp(system),
                         idle: clamp(idle), perCore: perCore)
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 100)
    }
}
