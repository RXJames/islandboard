import Foundation

/// Bounded histories owned by the service, updated once per sample on the
/// main actor. The latest model is handed to SwiftUI with its history array
/// already attached so views never need to reach into the store.
struct MonitorDataStore {
    private(set) var cpu: MonitorHistory
    private(set) var memory: MonitorHistory
    private(set) var networkDownload: MonitorHistory
    private(set) var networkUpload: MonitorHistory
    private(set) var diskRead: MonitorHistory
    private(set) var diskWrite: MonitorHistory
    private(set) var gpu: MonitorHistory

    init(historyLimit: Int) {
        cpu = MonitorHistory(capacity: historyLimit)
        memory = MonitorHistory(capacity: historyLimit)
        networkDownload = MonitorHistory(capacity: historyLimit)
        networkUpload = MonitorHistory(capacity: historyLimit)
        diskRead = MonitorHistory(capacity: historyLimit)
        diskWrite = MonitorHistory(capacity: historyLimit)
        gpu = MonitorHistory(capacity: historyLimit)
    }

    mutating func record(_ sample: DomainSample) -> DomainSample {
        switch sample {
        case .cpu(var stats):
            if stats.availability.isAvailable && !stats.isWarmingUp {
                cpu.append(stats.totalUsage)
            }
            stats.history = cpu.values
            return .cpu(stats)
        case .memory(var stats):
            if stats.availability.isAvailable {
                memory.append(stats.usagePercent)
            }
            stats.history = memory.values
            return .memory(stats)
        case .network(var stats):
            if stats.availability.isAvailable && !stats.isWarmingUp {
                networkDownload.append(stats.downloadBytesPerSecond)
                networkUpload.append(stats.uploadBytesPerSecond)
            }
            stats.historyDownload = networkDownload.values
            stats.historyUpload = networkUpload.values
            return .network(stats)
        case .disk(var stats):
            if stats.ioAvailability.isAvailable && !stats.isWarmingUp {
                diskRead.append(stats.readBytesPerSecond)
                diskWrite.append(stats.writeBytesPerSecond)
            }
            stats.historyRead = diskRead.values
            stats.historyWrite = diskWrite.values
            return .disk(stats)
        case .gpu(var stats):
            if stats.availability.isAvailable, let utilization = stats.totalUtilization {
                gpu.append(utilization)
            }
            stats.history = gpu.values
            return .gpu(stats)
        case .thermal, .processes:
            return sample
        case .unavailable:
            return sample
        }
    }
}
