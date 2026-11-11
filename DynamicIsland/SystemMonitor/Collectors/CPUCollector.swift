import Foundation

/// Per-core CPU tick snapshots. Owned by `MonitorEngine` (an actor), so its
/// mutable previous snapshot is never touched concurrently.
final class CPUCollector {
    private var previousTicks: [CPUUsageCalculator.CoreTicks]?
    private(set) var lastSampleAt: Date?

    func collect() -> CPUStats {
        let now = Date()
        let load = SysctlSupport.loadAverage()
        let uptime = SysctlSupport.uptime()

        guard let ticks = MachSupport.processorTicks() else {
            return CPUStats(
                availability: .unavailable(reason: "host_processor_info failed"),
                sampledAt: now,
                isWarmingUp: true,
                totalUsage: 0,
                userPercent: 0,
                systemPercent: 0,
                idlePercent: 0,
                perCore: [],
                loadAverage: load,
                uptime: uptime,
                history: []
            )
        }

        let breakdown = CPUUsageCalculator.calculate(previous: previousTicks, current: ticks)
        previousTicks = ticks
        lastSampleAt = now
        let values = breakdown ?? .zero(coreCount: ticks.count)

        return CPUStats(
            availability: .available,
            sampledAt: now,
            isWarmingUp: breakdown == nil,
            totalUsage: values.usage,
            userPercent: values.user,
            systemPercent: values.system,
            idlePercent: values.idle,
            perCore: values.perCore,
            loadAverage: load,
            uptime: uptime,
            history: []
        )
    }

    func reset() {
        previousTicks = nil
    }
}
