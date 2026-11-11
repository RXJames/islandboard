import Foundation

final class MemoryCollector {
    func collect() -> MemoryStats {
        let now = Date()
        guard let vm = MachSupport.vmStatistics() else {
            return unavailable(reason: "host_statistics64 failed", at: now)
        }
        guard let total = SysctlSupport.uint64("hw.memsize"), total > 0 else {
            return unavailable(reason: "hw.memsize unavailable", at: now)
        }

        let page = MachSupport.pageSize
        let active = UInt64(vm.active_count) * page
        let inactive = UInt64(vm.inactive_count) * page
        let speculative = UInt64(vm.speculative_count) * page
        let wired = UInt64(vm.wire_count) * page
        let compressed = UInt64(vm.compressor_page_count) * page
        let purgeable = UInt64(vm.purgeable_count) * page
        let external = UInt64(vm.external_page_count) * page

        let result = MemoryUsageCalculator.compute(
            totalBytes: total,
            activeBytes: active,
            inactiveBytes: inactive,
            speculativeBytes: speculative,
            wiredBytes: wired,
            compressedBytes: compressed,
            purgeableBytes: purgeable,
            externalBytes: external
        )

        let swap = SysctlSupport.swapUsage()
        let pressure = SysctlSupport.memoryPressureLevel().map(MemoryUsageCalculator.pressure) ?? .unknown

        return MemoryStats(
            availability: .available,
            sampledAt: now,
            totalBytes: total,
            usedBytes: result.usedBytes,
            freeBytes: result.freeBytes,
            activeBytes: active,
            inactiveBytes: inactive,
            wiredBytes: wired,
            compressedBytes: compressed,
            appBytes: result.appBytes,
            cacheBytes: result.cacheBytes,
            swapTotalBytes: swap?.total,
            swapUsedBytes: swap?.used,
            pressure: pressure,
            usagePercent: result.usagePercent,
            history: []
        )
    }

    private func unavailable(reason: String, at date: Date) -> MemoryStats {
        MemoryStats(
            availability: .unavailable(reason: reason),
            sampledAt: date,
            totalBytes: 0,
            usedBytes: 0,
            freeBytes: 0,
            activeBytes: 0,
            inactiveBytes: 0,
            wiredBytes: 0,
            compressedBytes: 0,
            appBytes: 0,
            cacheBytes: 0,
            swapTotalBytes: nil,
            swapUsedBytes: nil,
            pressure: .unknown,
            usagePercent: 0,
            history: []
        )
    }
}
