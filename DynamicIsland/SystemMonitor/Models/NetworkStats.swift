import Foundation

struct NetworkInterfaceStats: Identifiable, Equatable, Sendable {
    var name: String
    var isActive: Bool
    var ipv4: String?
    var ipv6: String?
    var downloadBytesPerSecond: Double
    var uploadBytesPerSecond: Double
    /// Cumulative bytes since this service started sampling the interface.
    var totalDownloadedBytes: UInt64
    var totalUploadedBytes: UInt64

    var id: String { name }
}

struct NetworkStats: Equatable, Sendable {
    var availability: MetricAvailability
    var sampledAt: Date
    /// True on the first sample and after a gap (sleep / hidden dashboard);
    /// rates are 0 then, but cumulative totals remain valid.
    var isWarmingUp: Bool
    var downloadBytesPerSecond: Double
    var uploadBytesPerSecond: Double
    var totalDownloadedBytes: UInt64
    var totalUploadedBytes: UInt64
    var interfaces: [NetworkInterfaceStats]
    var historyDownload: [Double]
    var historyUpload: [Double]
}

enum NetworkRateCalculator {
    /// 32-bit `if_data` counters wrap every 4 GiB. A decrease is interpreted
    /// as a wrap only when the previous value was near the 32-bit ceiling;
    /// otherwise it is an interface reset and the current value is counted.
    static func delta(current: UInt32, previous: UInt32) -> UInt64 {
        if current >= previous {
            return UInt64(current - previous)
        }
        let wrapThreshold: UInt32 = 0xF000_0000
        if previous >= wrapThreshold {
            return UInt64(UInt32.max - previous) + UInt64(current) + 1
        }
        return UInt64(current)
    }

    static func rate(delta: UInt64, elapsed: TimeInterval) -> Double {
        guard elapsed > 0, elapsed.isFinite else { return 0 }
        return Double(delta) / elapsed
    }
}
