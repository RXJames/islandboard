import Foundation

struct GPUDeviceStats: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var vendor: String?
    var isActive: Bool
    var utilization: Double?
    var renderUtilization: Double?
    var tilerUtilization: Double?
    var temperatureCelsius: Double?
    var fanSpeed: Int?
    var coreClockMHz: Int?
    var memoryClockMHz: Int?
    var cores: Int?
    var memoryUsedBytes: UInt64?
    var memoryTotalBytes: UInt64?

    init(device: GPUDeviceMetrics) {
        id = device.id
        name = device.formattedVendorModel
        vendor = device.vendor
        isActive = device.isActive
        utilization = device.utilization
        renderUtilization = device.renderUtilization
        tilerUtilization = device.tilerUtilization
        temperatureCelsius = device.temperature
        fanSpeed = device.fanSpeed
        coreClockMHz = device.coreClock
        memoryClockMHz = device.memoryClock
        cores = device.cores
        memoryUsedBytes = device.memoryUsedBytes
        memoryTotalBytes = device.memoryTotalBytes
    }
}

struct GPUStats: Equatable, Sendable {
    var availability: MetricAvailability
    var sampledAt: Date
    /// Nil when the GPU is present but the driver does not expose a usage
    /// counter; never fabricated.
    var totalUtilization: Double?
    var devices: [GPUDeviceStats]
    var history: [Double]
}
