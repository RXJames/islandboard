import Foundation

enum MonitorDomain: String, CaseIterable, Hashable, Sendable {
    case cpu
    case memory
    case network
    case disk
    case gpu
    case thermal
    case processes
}

/// A surface that consumes monitor data. Both the notch overview and the
/// dashboard register here so exactly one scheduler serves them.
enum MonitorSurface: Hashable, Sendable {
    case notch
    case dashboard(showProcesses: Bool)
}

struct MonitorConfiguration: Equatable, Sendable {
    var cpuInterval: TimeInterval = 1
    var memoryInterval: TimeInterval = 2
    var networkInterval: TimeInterval = 1
    var diskInterval: TimeInterval = 1
    var gpuInterval: TimeInterval = 2
    var thermalInterval: TimeInterval = 2
    var processInterval: TimeInterval = 3

    var historyLimit: Int = 120
    /// Scheduler granularity; never smaller than the fastest metric interval.
    var tickInterval: TimeInterval = 0.5
    /// A gap larger than this (sleep, dashboard hidden) resets rate baselines
    /// instead of reporting an average over the hidden period.
    var maxSampleGap: TimeInterval = 10

    static let `default` = MonitorConfiguration()

    func interval(for domain: MonitorDomain) -> TimeInterval {
        switch domain {
        case .cpu: return cpuInterval
        case .memory: return memoryInterval
        case .network: return networkInterval
        case .disk: return diskInterval
        case .gpu: return gpuInterval
        case .thermal: return thermalInterval
        case .processes: return processInterval
        }
    }

    /// Clamp user defaults to values the scheduler and ring buffers can honour.
    func sanitized() -> MonitorConfiguration {
        var copy = self
        copy.cpuInterval = Self.clamp(copy.cpuInterval, 0.25, 60)
        copy.memoryInterval = Self.clamp(copy.memoryInterval, 0.5, 120)
        copy.networkInterval = Self.clamp(copy.networkInterval, 0.25, 60)
        copy.diskInterval = Self.clamp(copy.diskInterval, 0.5, 120)
        copy.gpuInterval = Self.clamp(copy.gpuInterval, 0.5, 120)
        copy.thermalInterval = Self.clamp(copy.thermalInterval, 0.5, 120)
        copy.processInterval = Self.clamp(copy.processInterval, 1, 300)
        copy.historyLimit = Int(Self.clamp(Double(copy.historyLimit), 10, 600))
        copy.tickInterval = Self.clamp(copy.tickInterval, 0.1, 5)
        copy.tickInterval = min(copy.tickInterval, copy.cpuInterval, copy.networkInterval)
        copy.maxSampleGap = Self.clamp(copy.maxSampleGap, 2 * copy.tickInterval, 600)
        return copy
    }

    private static func clamp(_ value: TimeInterval, _ lower: TimeInterval, _ upper: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return lower }
        return min(max(value, lower), upper)
    }
}
