import SwiftUI

struct OverviewSection: View {
    let service: SystemMonitorService
    let onSelect: (MonitorSection) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 250, maximum: 380), spacing: 16)
    ]

    var body: some View {
        MonitorSectionScaffold(
            "Overview",
            subtitle: "Live snapshot from the shared monitor engine"
        ) {
            LazyVGrid(columns: columns, spacing: 16) {
                cpuCard
                gpuCard
                memoryCard
                networkCard
                diskCard
                temperaturesCard
            }
        }
    }

    private var cpuCard: some View {
        let cpu = service.cpu
        let available = cpu?.availability.isAvailable == true
        let percent = (available && cpu?.isWarmingUp == false) ? cpu?.totalUsage : nil
        let details: [String] = {
            guard let cpu, available else {
                return [cpu?.availability.displayText ?? "Collecting…"]
            }
            if cpu.isWarmingUp { return ["Warming up…"] }
            return [
                "\(cpu.perCore.count) cores",
                "user \(Int(cpu.userPercent.rounded()))% · sys \(Int(cpu.systemPercent.rounded()))%"
            ]
        }()
        return OverviewRingCard(
            title: "CPU",
            icon: "cpu",
            percent: percent,
            details: details,
            tint: MonitorPalette.cpu,
            availability: cpu?.availability ?? .unavailable(reason: "Collecting")
        ) {
            onSelect(.cpu)
        }
    }

    private var memoryCard: some View {
        let memory = service.memory
        let available = memory?.availability.isAvailable == true
        return OverviewMetricCard(
            title: "Memory",
            icon: "memorychip",
            value: available ? MonitorFormat.percent(memory?.usagePercent, digits: 0) : "—",
            detail: available
                ? (memory.map { "\(MonitorFormat.bytes($0.usedBytes)) of \(MonitorFormat.bytes($0.totalBytes)) · \($0.pressure.level.rawValue)" } ?? "Collecting…")
                : (memory?.availability.displayText ?? "Collecting…"),
            tint: MonitorPalette.memory,
            availability: memory?.availability ?? .unavailable(reason: "Collecting"),
            history: available ? (memory?.history ?? []) : []
        ) {
            onSelect(.memory)
        }
    }

    private var networkCard: some View {
        let network = service.network
        let available = network?.availability.isAvailable == true
        let detail: String = {
            guard let network, available else { return network?.availability.displayText ?? "Collecting…" }
            return "↑ \(MonitorFormat.rate(network.uploadBytesPerSecond)) · \(MonitorFormat.bytes(network.totalDownloadedBytes)) total"
        }()
        return OverviewMetricCard(
            title: "Network",
            icon: "network",
            value: available ? "↓ \(MonitorFormat.rate(network?.downloadBytesPerSecond ?? 0))" : "—",
            detail: detail,
            tint: MonitorPalette.network,
            availability: network?.availability ?? .unavailable(reason: "Collecting"),
            history: available ? (network?.historyDownload ?? []) : []
        ) {
            onSelect(.network)
        }
    }

    private var diskCard: some View {
        let disk = service.disk
        let root = disk?.volumes.first(where: \.isRoot) ?? disk?.volumes.first
        let detail: String = {
            guard let disk else { return "Collecting…" }
            return "R \(MonitorFormat.rate(disk.readBytesPerSecond)) · W \(MonitorFormat.rate(disk.writeBytesPerSecond))"
        }()
        return OverviewMetricCard(
            title: "Disk",
            icon: "internaldrive",
            value: root.map { MonitorFormat.percent($0.usagePercent, digits: 0) } ?? "—",
            detail: detail,
            tint: MonitorPalette.disk,
            availability: disk?.availability ?? .unavailable(reason: "Collecting"),
            history: disk?.historyRead ?? []
        ) {
            onSelect(.disk)
        }
    }

    private var gpuCard: some View {
        let gpu = service.gpu
        let available = gpu?.availability.isAvailable == true
        let percent = available ? gpu?.totalUtilization : nil
        let details: [String] = {
            guard let gpu, available else {
                return [gpu?.availability.displayText ?? "Collecting…"]
            }
            let device = gpu.devices.first
            var lines: [String] = []
            if let device {
                lines.append(device.name)
            }
            if let utilization = device?.utilization {
                var parts = ["GPU \(Int(utilization.rounded()))%"]
                if let render = device?.renderUtilization { parts.append("render \(Int(render.rounded()))%") }
                if let tiler = device?.tilerUtilization { parts.append("tiler \(Int(tiler.rounded()))%") }
                lines.append(parts.joined(separator: " · "))
            } else if device != nil {
                lines.append("Utilization not exposed")
            }
            return lines.isEmpty ? ["No GPU devices"] : lines
        }()
        return OverviewRingCard(
            title: "GPU",
            icon: "square.stack.3d.up",
            percent: percent,
            details: details,
            tint: MonitorPalette.gpu,
            availability: gpu?.availability ?? .unavailable(reason: "Collecting")
        ) {
            onSelect(.gpu)
        }
    }

    private var temperaturesCard: some View {
        OverviewTemperatureCard(thermal: service.thermal) {
            onSelect(.thermal)
        }
    }
}

private struct OverviewMetricCard: View {
    let title: String
    let icon: String
    let value: String
    let detail: String
    let tint: Color
    let availability: MetricAvailability
    let history: [Double]
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(tint.opacity(0.16))
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .frame(width: 24, height: 24)

                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                if !availability.isAvailable {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .help(availability.displayText ?? "Unavailable")
                }
            }

            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if history.count > 1 {
                OverviewSparkline(values: history, tint: tint)
                    .frame(height: 36)
            } else {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
                    .frame(height: 36)
                    .overlay(
                        Text("Collecting…")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    )
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture(perform: action)
        .help("Open \(title)")
    }
}

private struct OverviewRingCard: View {
    let title: String
    let icon: String
    let percent: Double?
    let details: [String]
    let tint: Color
    let availability: MetricAvailability
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(tint.opacity(0.16))
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .frame(width: 24, height: 24)

                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                if !availability.isAvailable {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .help(availability.displayText ?? "Unavailable")
                }
            }

            HStack(spacing: 14) {
                CircularGaugeView(
                    title: "",
                    value: min(max((percent ?? 0) / 100, 0), 1),
                    tint: tint,
                    centerPrimaryText: percent.map { MonitorFormat.percent($0, digits: 0) } ?? "—",
                    centerSecondaryText: "usage",
                    size: 92,
                    lineWidth: 9
                )

                VStack(alignment: .leading, spacing: 5) {
                    ForEach(details.indices, id: \.self) { index in
                        Text(details[index])
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 154, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture(perform: action)
        .help("Open \(title)")
    }
}

private struct OverviewTemperatureCard: View {
    let thermal: ThermalStats?
    let action: () -> Void

    private var readings: [TemperatureReading] {
        if let thermal { return thermal.sensors }
        return TemperatureReading.Kind.allCases.map { TemperatureReading(kind: $0, celsius: nil) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(MonitorPalette.thermal.opacity(0.16))
                    Image(systemName: "thermometer.medium")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(MonitorPalette.thermal)
                }
                .frame(width: 24, height: 24)

                Text("TEMPERATURES")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                if let thermal {
                    Text(thermal.level.displayName)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 7) {
                ForEach(readings) { reading in
                    HStack(spacing: 7) {
                        Image(systemName: reading.kind.symbolName)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(reading.kind.tint)
                            .frame(width: 14)
                        Text(reading.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 6)
                        Text(MonitorFormat.temperature(reading.celsius))
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                    }
                }
            }

            Spacer(minLength: 0)

            Text(thermal.map { "Fan: " + ($0.fanRPM.map { "\($0) RPM" } ?? "not exposed") } ?? "Collecting sensors…")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 154, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture(perform: action)
        .help("Open Thermal")
    }
}

private struct OverviewSparkline: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            let maxValue = max(values.max() ?? 0, 1)
            Path { path in
                guard values.count > 1 else { return }
                let step = geometry.size.width / CGFloat(values.count - 1)
                for (index, value) in values.enumerated() {
                    let point = CGPoint(
                        x: CGFloat(index) * step,
                        y: geometry.size.height * (1 - CGFloat(min(max(value / maxValue, 0), 1)))
                    )
                    if index == 0 {
                        path.move(to: point)
                    } else {
                        path.addLine(to: point)
                    }
                }
            }
            .stroke(tint, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }
    }
}
