import Foundation

/// One collector result. The service merges these into its published
/// per-domain properties; collectors never touch UI state directly.
enum DomainSample: Sendable {
    case cpu(CPUStats)
    case memory(MemoryStats)
    case network(NetworkStats)
    case disk(DiskStats)
    case gpu(GPUStats)
    case thermal(ThermalStats)
    case processes(ProcessStatsSnapshot)
    case unavailable(MonitorDomain, reason: String)

    var domain: MonitorDomain {
        switch self {
        case .cpu: return .cpu
        case .memory: return .memory
        case .network: return .network
        case .disk: return .disk
        case .gpu: return .gpu
        case .thermal: return .thermal
        case .processes: return .processes
        case .unavailable(let domain, _): return domain
        }
    }
}

struct MonitorSnapshot: Sendable {
    var cpu: CPUStats?
    var memory: MemoryStats?
    var network: NetworkStats?
    var disk: DiskStats?
    var gpu: GPUStats?
    var thermal: ThermalStats?
    var processes: ProcessStatsSnapshot?
    var sampledAt: Date
}
