import Foundation

/// Thermal state uses the public `ProcessInfo.thermalState`. CPU temperature
/// and fan RPM come from the same best-effort SMC/IOReport path the legacy
/// Stats tab already uses; those interfaces are private/undocumented, so
/// missing values stay nil instead of being guessed.
final class ThermalCollector {
    private let cpuSensors = CPUSensorCollector()

    // Curated SMC candidates. Missing keys are skipped; nothing is estimated.
    private static let gpuKeys = [
        "Tg0j", "Tg0U", "Tg0X", "Tg05", "Tg0D", "Tg0L", "Tg0P", "Tg0T", "Tg0f", "Tg0e"
    ]
    private static let memoryKeys = [
        "Tm00", "Tm01", "Tm02", "Tm0P", "Tm0p", "Tm0C", "Tm0D", "Tm0E", "Tm0F",
        "Tm0G", "Tm0H", "Tm0K", "Tm0L", "Tm0M", "Tm0N", "Tm0O", "Tm0Q", "Tm0R",
        "Tm0S", "Tm0T", "Tm0U", "Tm0V", "Tm0W", "Tm0X", "Tm0Y", "Tm0Z", "Tm1P", "Tm1p"
    ]
    private static let diskKeys = [
        "TH0x", "TH0P", "TH0p", "TH0D", "TH0d", "Ts0P", "Ts0p", "Ts0S", "Ts0s", "Ts0T", "Ts0t"
    ]

    func collect() -> ThermalStats {
        let level = ThermalLevel(ProcessInfo.processInfo.thermalState)
        let cpu = cpuSensors.readTemperature().celsius
        let gpu = averageTemperature(Self.gpuKeys)
        let memory = averageTemperature(Self.memoryKeys)
        let disk = averageTemperature(Self.diskKeys)
        let fan = ["F0Ac", "F1Ac"]
            .compactMap { SMC.shared.getValue($0) }
            .first
            .map { Int($0.rounded()) }

        let readings = [
            TemperatureReading(kind: .cpu, celsius: cpu),
            TemperatureReading(kind: .gpu, celsius: gpu),
            TemperatureReading(kind: .memory, celsius: memory),
            TemperatureReading(kind: .disk, celsius: disk)
        ]

        return ThermalStats(
            availability: .available,
            sampledAt: Date(),
            level: level,
            sensors: readings,
            cpuTemperatureCelsius: cpu,
            fanRPM: fan
        )
    }

    /// Average of whichever curated keys are readable; nil if none are.
    private func averageTemperature(_ keys: [String]) -> Double? {
        let values = keys.compactMap { key -> Double? in
            guard let value = SMC.shared.getValue(key), value > 0, value < 120 else { return nil }
            return value
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
