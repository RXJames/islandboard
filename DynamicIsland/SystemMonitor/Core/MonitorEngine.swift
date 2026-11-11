import Foundation

/// Owns all collectors and their previous-counter state. An actor, so
/// sampling is serialized and no lock is ever held during a syscall.
actor MonitorEngine {
    private let cpuCollector = CPUCollector()
    private let memoryCollector = MemoryCollector()
    private let networkCollector: NetworkCollector
    private let diskCollector: DiskCollector
    private let gpuCollector = GPUCollector()
    private let thermalCollector = ThermalCollector()
    private let processCollector: ProcessCollector

    init(configuration: MonitorConfiguration) {
        self.networkCollector = NetworkCollector(maxSampleGap: configuration.maxSampleGap)
        self.diskCollector = DiskCollector(maxSampleGap: configuration.maxSampleGap)
        self.processCollector = ProcessCollector(maxSampleGap: configuration.maxSampleGap)
    }

    func sample(_ domain: MonitorDomain) -> DomainSample {
        switch domain {
        case .cpu:
            return .cpu(cpuCollector.collect())
        case .memory:
            return .memory(memoryCollector.collect())
        case .network:
            return .network(networkCollector.collect())
        case .disk:
            return .disk(diskCollector.collect())
        case .gpu:
            return .gpu(gpuCollector.collect())
        case .thermal:
            return .thermal(thermalCollector.collect())
        case .processes:
            return .processes(processCollector.collect())
        }
    }

    func resetBaselines() {
        cpuCollector.reset()
        networkCollector.resetBaseline()
        diskCollector.resetBaseline()
        processCollector.resetBaseline()
    }
}
