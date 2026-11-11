import Foundation

struct MemoryStats: Equatable, Sendable {
    var availability: MetricAvailability
    var sampledAt: Date
    var totalBytes: UInt64
    var usedBytes: UInt64
    var freeBytes: UInt64
    var activeBytes: UInt64
    var inactiveBytes: UInt64
    var wiredBytes: UInt64
    var compressedBytes: UInt64
    var appBytes: UInt64
    var cacheBytes: UInt64
    var swapTotalBytes: UInt64?
    var swapUsedBytes: UInt64?
    var pressure: MemoryPressure
    var usagePercent: Double
    var history: [Double]
}

/// Same semantics as Activity Monitor and the existing Stats tab:
/// used = active + inactive + speculative + wired + compressed
///        − (purgeable + external), clamped to installed RAM.
enum MemoryUsageCalculator {
    struct Result: Equatable, Sendable {
        var usedBytes: UInt64
        var appBytes: UInt64
        var cacheBytes: UInt64
        var freeBytes: UInt64
        var usagePercent: Double
    }

    static func compute(
        totalBytes: UInt64,
        activeBytes: UInt64,
        inactiveBytes: UInt64,
        speculativeBytes: UInt64,
        wiredBytes: UInt64,
        compressedBytes: UInt64,
        purgeableBytes: UInt64,
        externalBytes: UInt64
    ) -> Result {
        guard totalBytes > 0 else {
            return Result(usedBytes: 0, appBytes: 0, cacheBytes: 0, freeBytes: 0, usagePercent: 0)
        }
        let usedWithoutCache = activeBytes
            .addingReportingOverflow(inactiveBytes).partialValue
            .addingReportingOverflow(speculativeBytes).partialValue
            .addingReportingOverflow(wiredBytes).partialValue
            .addingReportingOverflow(compressedBytes).partialValue
        let cache = purgeableBytes.addingReportingOverflow(externalBytes).partialValue
        let used = min(usedWithoutCache > cache ? usedWithoutCache - cache : 0, totalBytes)
        let free = totalBytes - used
        let nonApp = wiredBytes.addingReportingOverflow(compressedBytes).partialValue
        let app = used > nonApp ? used - nonApp : 0
        let usage = Double(used) / Double(totalBytes) * 100
        return Result(usedBytes: used, appBytes: app, cacheBytes: cache,
                      freeBytes: free, usagePercent: min(max(usage, 0), 100))
    }

    static func pressure(from rawLevel: Int32) -> MemoryPressure {
        let level: MemoryPressureLevel
        switch rawLevel {
        case 2: level = .warning
        case 4: level = .critical
        default: level = .normal
        }
        return MemoryPressure(rawValue: Int(rawLevel), level: level)
    }
}
