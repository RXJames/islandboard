import Darwin
import Foundation

/// Network throughput from `getifaddrs` + `if_data` counters. The legacy
/// `if_data` counters are 32-bit, so deltas are wrap-aware and interface
/// resets are handled explicitly. Cumulative totals are "since this service
/// started sampling", not since boot, and are documented as such.
final class NetworkCollector {
    private struct Counters: Equatable {
        var bytesIn: UInt32
        var bytesOut: UInt32
    }

    private struct RawInterface {
        var name: String
        var flags: UInt32
        var bytesIn: UInt32
        var bytesOut: UInt32
        var ipv4: String?
        var ipv6: String?
        var hasLinkData: Bool
    }

    private var previous: [String: Counters]?
    private var previousTime: Date?
    private var totals: [String: (down: UInt64, up: UInt64)] = [:]
    private let maxSampleGap: TimeInterval

    init(maxSampleGap: TimeInterval = 10) {
        self.maxSampleGap = maxSampleGap
    }

    func collect() -> NetworkStats {
        let now = Date()
        guard let rawInterfaces = Self.readInterfaces() else {
            return NetworkStats(
                availability: .unavailable(reason: "getifaddrs failed"),
                sampledAt: now,
                isWarmingUp: true,
                downloadBytesPerSecond: 0,
                uploadBytesPerSecond: 0,
                totalDownloadedBytes: 0,
                totalUploadedBytes: 0,
                interfaces: [],
                historyDownload: [],
                historyUpload: []
            )
        }

        let elapsed = previousTime.map { now.timeIntervalSince($0) }
        let canComputeRate = elapsed.map { $0 > 0 && $0 <= maxSampleGap } ?? false

        var interfaces: [NetworkInterfaceStats] = []
        var nextCounters: [String: Counters] = [:]
        var aggregateDown: UInt64 = 0
        var aggregateUp: UInt64 = 0
        var aggregateDownRate = 0.0
        var aggregateUpRate = 0.0

        for interface in rawInterfaces {
            let previousCounters = previous?[interface.name]
            let deltaDown = previousCounters.map {
                NetworkRateCalculator.delta(current: interface.bytesIn, previous: $0.bytesIn)
            } ?? 0
            let deltaUp = previousCounters.map {
                NetworkRateCalculator.delta(current: interface.bytesOut, previous: $0.bytesOut)
            } ?? 0

            var running = totals[interface.name] ?? (down: 0, up: 0)
            running.down = running.down.addingReportingOverflow(deltaDown).partialValue
            running.up = running.up.addingReportingOverflow(deltaUp).partialValue
            totals[interface.name] = running

            let downRate = canComputeRate
                ? NetworkRateCalculator.rate(delta: deltaDown, elapsed: elapsed ?? 0)
                : 0
            let upRate = canComputeRate
                ? NetworkRateCalculator.rate(delta: deltaUp, elapsed: elapsed ?? 0)
                : 0

            aggregateDown = aggregateDown.addingReportingOverflow(running.down).partialValue
            aggregateUp = aggregateUp.addingReportingOverflow(running.up).partialValue
            aggregateDownRate += downRate
            aggregateUpRate += upRate

            interfaces.append(
                NetworkInterfaceStats(
                    name: interface.name,
                    isActive: interface.flags & UInt32(IFF_UP) != 0,
                    ipv4: interface.ipv4,
                    ipv6: interface.ipv6,
                    downloadBytesPerSecond: downRate,
                    uploadBytesPerSecond: upRate,
                    totalDownloadedBytes: running.down,
                    totalUploadedBytes: running.up
                )
            )
            nextCounters[interface.name] = Counters(
                bytesIn: interface.bytesIn,
                bytesOut: interface.bytesOut
            )
        }

        previous = nextCounters
        previousTime = now

        return NetworkStats(
            availability: .available,
            sampledAt: now,
            isWarmingUp: !canComputeRate,
            downloadBytesPerSecond: canComputeRate ? aggregateDownRate : 0,
            uploadBytesPerSecond: canComputeRate ? aggregateUpRate : 0,
            totalDownloadedBytes: aggregateDown,
            totalUploadedBytes: aggregateUp,
            interfaces: interfaces,
            historyDownload: [],
            historyUpload: []
        )
    }

    /// Drop the rate baseline (sleep/wake, surface changes) but keep the
    /// since-launch totals.
    func resetBaseline() {
        previous = nil
        previousTime = nil
    }

    // MARK: - getifaddrs

    private static func readInterfaces() -> [RawInterface]? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let start = pointer else {
            return nil
        }
        defer { freeifaddrs(start) }

        var accumulators: [String: RawInterface] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = start
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let interface = current.pointee
            let name = String(cString: interface.ifa_name)
            guard shouldInclude(name: name) else { continue }

            var accumulator = accumulators[name] ?? RawInterface(
                name: name,
                flags: interface.ifa_flags,
                bytesIn: 0,
                bytesOut: 0,
                ipv4: nil,
                ipv6: nil,
                hasLinkData: false
            )
            accumulator.flags = interface.ifa_flags

            if let address = interface.ifa_addr {
                switch Int32(address.pointee.sa_family) {
                case AF_LINK:
                    if let data = interface.ifa_data?.assumingMemoryBound(to: if_data.self) {
                        accumulator.bytesIn = data.pointee.ifi_ibytes
                        accumulator.bytesOut = data.pointee.ifi_obytes
                        accumulator.hasLinkData = true
                    }
                case AF_INET:
                    accumulator.ipv4 = addressString(address)
                case AF_INET6:
                    accumulator.ipv6 = addressString(address)
                default:
                    break
                }
            }
            accumulators[name] = accumulator
        }

        return accumulators.values
            .filter { $0.hasLinkData }
            .sorted { $0.name < $1.name }
    }

    private static func shouldInclude(name: String) -> Bool {
        name.hasPrefix("en")
    }

    private static func addressString(_ address: UnsafePointer<sockaddr>) -> String? {
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            var value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &value, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
            return String(cString: buffer)
        case AF_INET6:
            var value = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &value, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else { return nil }
            return String(cString: buffer)
        default:
            return nil
        }
    }
}
