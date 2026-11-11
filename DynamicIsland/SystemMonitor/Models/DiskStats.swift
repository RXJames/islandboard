import Foundation

struct DiskVolumeStats: Identifiable, Equatable, Sendable {
    var mountPoint: String
    var name: String
    var totalBytes: UInt64
    var freeBytes: UInt64
    var usedBytes: UInt64
    var usagePercent: Double
    var isRoot: Bool
    var isLocal: Bool
    var isRemovable: Bool

    var id: String { mountPoint }
}

struct DiskStats: Equatable, Sendable {
    /// Capacity and I/O are independent: a volume list can work while the
    /// IOKit counters are unavailable (or vice versa).
    var availability: MetricAvailability
    var ioAvailability: MetricAvailability
    var sampledAt: Date
    var isWarmingUp: Bool
    var volumes: [DiskVolumeStats]
    var readBytesPerSecond: Double
    var writeBytesPerSecond: Double
    var totalReadBytes: UInt64
    var totalWrittenBytes: UInt64
    var historyRead: [Double]
    var historyWrite: [Double]
}

enum DiskUsageCalculator {
    static func usagePercent(total: UInt64, free: UInt64) -> Double {
        guard total > 0 else { return 0 }
        let used = total > free ? total - free : 0
        return min(max(Double(used) / Double(total) * 100, 0), 100)
    }

    static func rate(delta: UInt64, elapsed: TimeInterval) -> Double {
        guard elapsed > 0, elapsed.isFinite else { return 0 }
        return Double(delta) / elapsed
    }
}
