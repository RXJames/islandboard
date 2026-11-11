import Foundation

enum ThermalLevel: String, CaseIterable, Sendable {
    case nominal
    case fair
    case serious
    case critical
    case unknown

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .unknown
        }
    }

    var displayName: String {
        rawValue.capitalized
    }
}

struct TemperatureReading: Identifiable, Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case cpu
        case gpu
        case memory
        case disk

        var label: String {
            switch self {
            case .cpu: return "CPU"
            case .gpu: return "GPU"
            case .memory: return "Memory"
            case .disk: return "Disk"
            }
        }
    }

    var kind: Kind
    /// Best-effort SMC reading; nil when this machine does not expose it.
    var celsius: Double?

    var id: String { kind.rawValue }
    var label: String { kind.label }
}

struct ThermalStats: Equatable, Sendable {
    var availability: MetricAvailability
    var sampledAt: Date
    /// Stable, public source (`ProcessInfo.thermalState`).
    var level: ThermalLevel
    /// CPU/GPU/Memory/Disk temperatures. Missing sensors keep `nil`; the UI
    /// lists them explicitly instead of drawing a graph or inventing values.
    var sensors: [TemperatureReading]
    /// Convenience mirror of the CPU sensor for the compact notch card.
    var cpuTemperatureCelsius: Double?
    var fanRPM: Int?
}
