import SwiftUI

struct MemorySection: View {
    let service: SystemMonitorService

    var body: some View {
        MonitorSectionScaffold(
            "Memory",
            subtitle: "Physical memory breakdown · used excludes reclaimable cache"
        ) {
            if let memory = service.memory {
                if memory.availability.isAvailable {
                HStack(alignment: .top, spacing: 16) {
                    MonitorCard(title: "Utilization", icon: "memorychip", tint: MonitorPalette.memory) {
                        HStack(spacing: 20) {
                            CircularGaugeView(
                                title: "Memory",
                                value: min(max(memory.usagePercent / 100, 0), 1),
                                tint: MonitorPalette.memory,
                                centerPrimaryText: MonitorFormat.percent(memory.usagePercent, digits: 0),
                                centerSecondaryText: "\(MonitorFormat.bytes(memory.usedBytes)) used",
                                size: 132,
                                lineWidth: 12
                            )
                            VStack(alignment: .leading, spacing: 8) {
                                MonitorStatRow(label: "Installed", value: MonitorFormat.bytes(memory.totalBytes))
                                MonitorStatRow(label: "Used", value: MonitorFormat.bytes(memory.usedBytes), tint: MonitorPalette.memory)
                                MonitorStatRow(label: "Free", value: MonitorFormat.bytes(memory.freeBytes))
                                MonitorStatRow(label: "Swap", value: MonitorFormat.bytes(memory.swapUsedBytes))
                                MonitorStatRow(label: "Pressure", value: memory.pressure.level.rawValue.capitalized, tint: pressureColor(memory.pressure.level))
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .frame(maxWidth: .infinity)

                    MonitorCard(title: "History", icon: "chart.xyaxis.line", tint: MonitorPalette.memory) {
                        MonitorHistoryChart(
                            primary: memory.history,
                            primaryTint: MonitorPalette.memory,
                            primaryLabel: "Used memory",
                            upperBound: 100,
                            height: 132
                        )
                    }
                    .frame(maxWidth: .infinity)
                }

                MonitorCard(title: "Breakdown", icon: "chart.bar.fill", tint: MonitorPalette.memory, subtitle: "Used = app + wired + compressed · cache is reclaimable") {
                    MemoryBreakdownBar(memory: memory)
                        .frame(height: 18)
                    HStack(spacing: 14) {
                        legend("App", MonitorPalette.memory)
                        legend("Wired", MonitorPalette.thermal)
                        legend("Compressed", MonitorPalette.gpu)
                        legend("Free", .secondary)
                        Spacer()
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], spacing: 8) {
                        MonitorStatRow(label: "Active", value: MonitorFormat.bytes(memory.activeBytes))
                        MonitorStatRow(label: "Inactive", value: MonitorFormat.bytes(memory.inactiveBytes))
                        MonitorStatRow(label: "Wired", value: MonitorFormat.bytes(memory.wiredBytes), tint: MonitorPalette.thermal)
                        MonitorStatRow(label: "Compressed", value: MonitorFormat.bytes(memory.compressedBytes), tint: MonitorPalette.gpu)
                        MonitorStatRow(label: "App memory", value: MonitorFormat.bytes(memory.appBytes), tint: MonitorPalette.memory)
                        MonitorStatRow(label: "Cache", value: MonitorFormat.bytes(memory.cacheBytes))
                        MonitorStatRow(label: "Free", value: MonitorFormat.bytes(memory.freeBytes))
                        MonitorStatRow(label: "Swap total", value: MonitorFormat.bytes(memory.swapTotalBytes))
                        MonitorStatRow(label: "Swap used", value: MonitorFormat.bytes(memory.swapUsedBytes))
                    }
                }
                } else {
                    MonitorEmptyState(
                        icon: "memorychip",
                        title: "Memory unavailable",
                        message: memory.availability.displayText ?? "host_statistics64 failed"
                    )
                }
            } else {
                MonitorEmptyState(
                    icon: "memorychip",
                    title: "Collecting memory data",
                    message: "host_statistics64 provides the first snapshot immediately."
                )
            }
        }
    }

    private func legend(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func pressureColor(_ level: MemoryPressureLevel) -> Color {
        switch level {
        case .normal: return MonitorPalette.memory
        case .warning: return MonitorPalette.disk
        case .critical: return MonitorPalette.thermal
        }
    }
}

private struct MemoryBreakdownBar: View {
    let memory: MemoryStats

    var body: some View {
        GeometryReader { geometry in
            let segments: [(Double, Color)] = [
                (Double(memory.wiredBytes), MonitorPalette.thermal),
                (Double(memory.compressedBytes), MonitorPalette.gpu),
                (Double(memory.appBytes), MonitorPalette.memory),
                (Double(memory.freeBytes), Color.secondary.opacity(0.35))
            ]
            let denominator = max(segments.reduce(0) { $0 + $1.0 }, 1)
            HStack(spacing: 0) {
                ForEach(segments.indices, id: \.self) { index in
                    Rectangle()
                        .fill(segments[index].1)
                        .frame(width: geometry.size.width * CGFloat(min(segments[index].0 / denominator, 1)))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}
