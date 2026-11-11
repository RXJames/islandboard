import SwiftUI

enum MonitorPalette {
    static let cpu = Color(red: 0.36, green: 0.62, blue: 0.96)
    static let memory = Color(red: 0.36, green: 0.79, blue: 0.55)
    static let network = Color(red: 0.33, green: 0.76, blue: 0.78)
    static let disk = Color(red: 0.95, green: 0.67, blue: 0.33)
    static let gpu = Color(red: 0.64, green: 0.52, blue: 0.95)
    static let thermal = Color(red: 0.95, green: 0.45, blue: 0.45)
}

enum MonitorFormat {
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .memory
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    static func bytes(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        if value == 0 { return "0 B" }
        return byteFormatter.string(fromByteCount: Int64(value))
    }

    static func bytes(_ value: Double) -> String {
        byteFormatter.string(fromByteCount: Int64(max(0, value)))
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "0 B/s" }
        let units = ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"]
        var value = bytesPerSecond
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        let digits: Int = value >= 100 ? 0 : (value >= 10 ? 1 : 2)
        return String(format: "%.\(digits)f %@", value, units[index])
    }

    static func percent(_ value: Double?, digits: Int = 1) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.\(digits)f%%", value)
    }

    static func temperature(_ celsius: Double?) -> String {
        guard let celsius, celsius.isFinite else { return "—" }
        return String(format: "%.1f °C", celsius)
    }

    static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else { return "—" }
        let total = Int(seconds)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    static func load(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.2f", value)
    }
}

struct MonitorProgressBar: View {
    let fraction: Double
    let tint: Color
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(tint)
                    .frame(width: max(height, geometry.size.width * CGFloat(min(max(fraction, 0), 1))))
            }
        }
        .frame(height: height)
    }
}

struct MonitorAvailabilityBadge: View {
    let availability: MetricAvailability

    var body: some View {
        if let text = availability.displayText {
            Label(text, systemImage: icon)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(Color.primary.opacity(0.06))
                )
        }
    }

    private var icon: String {
        switch availability {
        case .available: return "checkmark"
        case .permissionRestricted: return "lock.fill"
        default: return "exclamationmark.triangle.fill"
        }
    }
}

struct MonitorEmptyState: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}


extension TemperatureReading.Kind {
    var symbolName: String {
        switch self {
        case .cpu: return "cpu"
        case .gpu: return "square.stack.3d.up"
        case .memory: return "memorychip"
        case .disk: return "internaldrive"
        }
    }

    var tint: Color {
        switch self {
        case .cpu: return MonitorPalette.cpu
        case .gpu: return MonitorPalette.gpu
        case .memory: return MonitorPalette.memory
        case .disk: return MonitorPalette.disk
        }
    }
}
