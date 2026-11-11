import Foundation
import IOKit

/// Capacity comes from the mounted-volume API (Finder semantics); I/O comes
/// from the IOKit `IOBlockStorageDriver` counters, which are cumulative since
/// boot and differentiated here. They are independent sources and reported
/// with independent availability.
final class DiskCollector {
    private var previousRead: UInt64?
    private var previousWritten: UInt64?
    private var previousTime: Date?
    private let maxSampleGap: TimeInterval

    init(maxSampleGap: TimeInterval = 10) {
        self.maxSampleGap = maxSampleGap
    }

    func collect() -> DiskStats {
        let now = Date()
        let volumes = Self.readVolumes()
        let capacityAvailability: MetricAvailability = volumes.isEmpty
            ? .unavailable(reason: "No mounted volumes")
            : .available

        var ioAvailability: MetricAvailability = .unavailable(
            reason: "IOBlockStorageDriver counters unavailable"
        )
        var readRate = 0.0
        var writeRate = 0.0
        var totalRead: UInt64 = 0
        var totalWritten: UInt64 = 0
        var isWarmingUp = true

        if let totals = Self.readIOTotals() {
            ioAvailability = .available
            totalRead = totals.read
            totalWritten = totals.written

            if let previousRead, let previousWritten, let previousTime {
                let elapsed = now.timeIntervalSince(previousTime)
                if elapsed > 0, elapsed <= maxSampleGap {
                    let deltaRead = totalRead >= previousRead ? totalRead - previousRead : 0
                    let deltaWritten = totalWritten >= previousWritten ? totalWritten - previousWritten : 0
                    readRate = DiskUsageCalculator.rate(delta: deltaRead, elapsed: elapsed)
                    writeRate = DiskUsageCalculator.rate(delta: deltaWritten, elapsed: elapsed)
                    isWarmingUp = false
                }
            }

            self.previousRead = totalRead
            self.previousWritten = totalWritten
            self.previousTime = now
        }

        return DiskStats(
            availability: capacityAvailability,
            ioAvailability: ioAvailability,
            sampledAt: now,
            isWarmingUp: isWarmingUp,
            volumes: volumes,
            readBytesPerSecond: readRate,
            writeBytesPerSecond: writeRate,
            totalReadBytes: totalRead,
            totalWrittenBytes: totalWritten,
            historyRead: [],
            historyWrite: []
        )
    }

    func resetBaseline() {
        previousRead = nil
        previousWritten = nil
        previousTime = nil
    }

    // MARK: - Capacity

    private static func readVolumes() -> [DiskVolumeStats] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityForOpportunisticUsageKey,
            .volumeIsLocalKey,
            .volumeIsRemovableKey
        ]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else {
            return []
        }

        var seen = Set<String>()
        var volumes: [DiskVolumeStats] = []
        for url in urls {
            let mountPoint = url.path
            guard seen.insert(mountPoint).inserted else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let total = values.volumeTotalCapacity,
                  total > 0 else {
                continue
            }

            let totalBytes = UInt64(total)
            // Strict free space first (matches `df` and the existing Stats tab);
            // purgeable "important usage" capacity is only a fallback.
            let freeCapacity: Int64
            if let free = values.volumeAvailableCapacity {
                freeCapacity = Int64(free)
            } else if let important = values.volumeAvailableCapacityForImportantUsage {
                freeCapacity = important
            } else if let opportunistic = values.volumeAvailableCapacityForOpportunisticUsage {
                freeCapacity = opportunistic
            } else {
                freeCapacity = 0
            }
            let freeBytes = min(UInt64(max(0, freeCapacity)), totalBytes)
            let isRoot = values.volumeIsRootFileSystem ?? (mountPoint == "/")
            let name = values.volumeName ?? (isRoot ? "Macintosh HD" : url.lastPathComponent)

            volumes.append(
                DiskVolumeStats(
                    mountPoint: mountPoint,
                    name: name,
                    totalBytes: totalBytes,
                    freeBytes: freeBytes,
                    usedBytes: totalBytes > freeBytes ? totalBytes - freeBytes : 0,
                    usagePercent: DiskUsageCalculator.usagePercent(total: totalBytes, free: freeBytes),
                    isRoot: isRoot,
                    isLocal: values.volumeIsLocal ?? true,
                    isRemovable: values.volumeIsRemovable ?? false
                )
            )
        }

        volumes.sort { lhs, rhs in
            if lhs.isRoot != rhs.isRoot { return lhs.isRoot }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return volumes
    }

    // MARK: - I/O

    private static func readIOTotals() -> (read: UInt64, written: UInt64)? {
        guard let matching = IOServiceMatching("IOBlockStorageDriver") else {
            return nil
        }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var read: UInt64 = 0
        var written: UInt64 = 0
        var services = 0
        var foundCounter = false
        var service = IOIteratorNext(iterator)

        while service != 0 {
            services += 1
            var properties: Unmanaged<CFMutableDictionary>?
            let result = IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)
            if result == KERN_SUCCESS,
               let dictionary = properties?.takeRetainedValue() as? [String: Any],
               let statistics = dictionary["Statistics"] as? [String: Any] {
                if let value = number(in: statistics, keys: ["Bytes (Read)", "Bytes read from block device"]) {
                    read = read.addingReportingOverflow(UInt64(max(0, value))).partialValue
                    foundCounter = true
                }
                if let value = number(in: statistics, keys: ["Bytes (Write)", "Bytes written to block device"]) {
                    written = written.addingReportingOverflow(UInt64(max(0, value))).partialValue
                    foundCounter = true
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }

        guard services > 0, foundCounter else { return nil }
        return (read, written)
    }

    private static func number(in dictionary: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let number = dictionary[key] as? NSNumber {
                return number.doubleValue
            }
            if let value = dictionary[key] as? Int64 {
                return Double(value)
            }
            if let value = dictionary[key] as? Int {
                return Double(value)
            }
            if let value = dictionary[key] as? Double {
                return value
            }
        }
        return nil
    }
}
