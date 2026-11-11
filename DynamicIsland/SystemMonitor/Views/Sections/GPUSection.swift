import SwiftUI

struct GPUSection: View {
    let service: SystemMonitorService

    var body: some View {
        MonitorSectionScaffold(
            "GPU",
            subtitle: "IOAccelerator performance statistics · unsupported fields stay unavailable"
        ) {
            if let gpu = service.gpu, !gpu.devices.isEmpty {
                MonitorCard(title: "History", icon: "chart.xyaxis.line", tint: MonitorPalette.gpu, subtitle: "Average device utilization") {
                    MonitorHistoryChart(
                        primary: gpu.history,
                        primaryTint: MonitorPalette.gpu,
                        primaryLabel: "GPU usage",
                        upperBound: 100,
                        height: 160
                    )
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16)], spacing: 16) {
                    ForEach(gpu.devices) { device in
                        deviceCard(device)
                    }
                }
            } else {
                MonitorEmptyState(
                    icon: "square.stack.3d.up.slash",
                    title: "GPU unavailable",
                    message: service.gpu?.availability.displayText ?? "No IOAccelerator device was reported."
                )
            }
        }
    }

    private func deviceCard(_ device: GPUDeviceStats) -> some View {
        MonitorCard(
            title: device.name,
            icon: "square.stack.3d.up",
            tint: MonitorPalette.gpu,
            subtitle: device.isActive ? "Active" : "Idle"
        ) {
            HStack(alignment: .center, spacing: 18) {
                if let utilization = device.utilization {
                    CircularGaugeView(
                        title: "GPU",
                        value: min(max(utilization / 100, 0), 1),
                        tint: MonitorPalette.gpu,
                        centerPrimaryText: MonitorFormat.percent(utilization, digits: 0),
                        centerSecondaryText: "utilization",
                        size: 104,
                        lineWidth: 10
                    )
                } else {
                    VStack(spacing: 4) {
                        Text("—")
                            .font(.system(size: 24, weight: .semibold))
                        Text("Not exposed")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 104, height: 104)
                }

                VStack(alignment: .leading, spacing: 6) {
                    if let render = device.renderUtilization {
                        MonitorStatRow(label: "Renderer", value: MonitorFormat.percent(render), tint: MonitorPalette.gpu)
                    }
                    if let tiler = device.tilerUtilization {
                        MonitorStatRow(label: "Tiler", value: MonitorFormat.percent(tiler), tint: MonitorPalette.gpu)
                    }
                    if let temperature = device.temperatureCelsius {
                        MonitorStatRow(label: "Temperature", value: MonitorFormat.temperature(temperature), tint: MonitorPalette.thermal)
                    }
                    if let fan = device.fanSpeed {
                        MonitorStatRow(label: "Fan", value: "\(fan) RPM")
                    }
                    if let coreClock = device.coreClockMHz {
                        MonitorStatRow(label: "Core clock", value: "\(coreClock) MHz")
                    }
                    if let memoryClock = device.memoryClockMHz {
                        MonitorStatRow(label: "Memory clock", value: "\(memoryClock) MHz")
                    }
                }
                Spacer(minLength: 0)
            }

            if let used = device.memoryUsedBytes {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Memory in use")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let total = device.memoryTotalBytes, total > 0 {
                            Text("\(MonitorFormat.bytes(used)) of \(MonitorFormat.bytes(total))")
                        } else {
                            Text(MonitorFormat.bytes(used))
                        }
                    }
                    .font(.caption2)
                    if let total = device.memoryTotalBytes, total > 0 {
                        MonitorProgressBar(
                            fraction: Double(used) / Double(total),
                            tint: MonitorPalette.gpu,
                            height: 6
                        )
                    }
                }
            }
        }
    }
}
