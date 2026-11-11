import Foundation

/// Maps the shared IOAccelerator reader into the monitor model. No synthetic
/// breakdown: fields the driver does not expose stay nil.
final class GPUCollector {
    private let provider = GPUInfoCollector()

    func collect() -> GPUStats {
        let now = Date()
        let devices = provider.collectDevices().map(GPUDeviceStats.init)
        guard !devices.isEmpty else {
            return GPUStats(
                availability: .unavailable(reason: "No IOAccelerator devices"),
                sampledAt: now,
                totalUtilization: nil,
                devices: [],
                history: []
            )
        }

        let utilizations = devices.compactMap(\.utilization)
        let total = utilizations.isEmpty
            ? nil
            : utilizations.reduce(0, +) / Double(utilizations.count)

        return GPUStats(
            availability: .available,
            sampledAt: now,
            totalUtilization: total,
            devices: devices.sorted { $0.id < $1.id },
            history: []
        )
    }
}
