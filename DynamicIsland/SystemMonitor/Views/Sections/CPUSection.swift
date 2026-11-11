import SwiftUI

struct CPUSection: View {
    let service: SystemMonitorService

    var body: some View {
        MonitorSectionScaffold(
            "CPU",
            subtitle: "Mach per-core tick deltas · 100% = one logical core"
        ) {
            if let cpu = service.cpu {
                if cpu.availability.isAvailable {
                HStack(alignment: .top, spacing: 16) {
                    MonitorCard(title: "Utilization", icon: "cpu", tint: MonitorPalette.cpu) {
                        HStack(spacing: 20) {
                            CircularGaugeView(
                                title: "CPU",
                                value: min(max(cpu.totalUsage / 100, 0), 1),
                                tint: MonitorPalette.cpu,
                                centerPrimaryText: MonitorFormat.percent(cpu.totalUsage, digits: 0),
                                centerSecondaryText: "\(cpu.perCore.count) cores",
                                size: 132,
                                lineWidth: 12
                            )
                            VStack(alignment: .leading, spacing: 8) {
                                MonitorStatRow(label: "User", value: MonitorFormat.percent(cpu.userPercent, digits: 1), tint: MonitorPalette.cpu)
                                MonitorStatRow(label: "System", value: MonitorFormat.percent(cpu.systemPercent, digits: 1), tint: MonitorPalette.thermal)
                                MonitorStatRow(label: "Idle", value: MonitorFormat.percent(cpu.idlePercent, digits: 1), tint: .secondary)
                                MonitorStatRow(label: "Load 1m", value: MonitorFormat.load(cpu.loadAverage?.oneMinute))
                                MonitorStatRow(label: "Uptime", value: MonitorFormat.duration(cpu.uptime))
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .frame(maxWidth: .infinity)

                    MonitorCard(title: "History", icon: "chart.xyaxis.line", tint: MonitorPalette.cpu) {
                        MonitorHistoryChart(
                            primary: cpu.history,
                            primaryTint: MonitorPalette.cpu,
                            primaryLabel: "CPU usage",
                            upperBound: 100,
                            height: 132
                        )
                    }
                    .frame(maxWidth: .infinity)
                }

                MonitorCard(title: "Per-Core Usage", icon: "cpu", tint: MonitorPalette.cpu, subtitle: "\(cpu.perCore.count) logical cores") {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 42, maximum: 64), spacing: 8)],
                        spacing: 8
                    ) {
                        ForEach(cpu.perCore.indices, id: \.self) { index in
                            let usage = cpu.perCore[index]
                            VStack(spacing: 4) {
                                ZStack(alignment: .bottom) {
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(Color.primary.opacity(0.06))
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(coreColor(usage))
                                        .frame(height: max(2, 64 * CGFloat(min(max(usage / 100, 0), 1))))
                                }
                                .frame(height: 64)
                                Text("\(index + 1)")
                                    .font(.system(size: 9).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text(MonitorFormat.percent(usage, digits: 0))
                                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                            }
                            .help("Core \(index + 1): \(MonitorFormat.percent(usage, digits: 1))")
                        }
                    }
                }

                HStack(spacing: 16) {
                    MonitorCard(title: "Load Average", icon: "waveform.path.ecg", tint: MonitorPalette.cpu) {
                        HStack(spacing: 24) {
                            loadValue("1 min", cpu.loadAverage?.oneMinute)
                            loadValue("5 min", cpu.loadAverage?.fiveMinutes)
                            loadValue("15 min", cpu.loadAverage?.fifteenMinutes)
                            Spacer()
                        }
                    }
                    MonitorCard(title: "Uptime", icon: "clock", tint: MonitorPalette.cpu) {
                        Text(MonitorFormat.duration(cpu.uptime))
                            .font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
                    }
                }
                } else {
                    MonitorEmptyState(
                        icon: "cpu",
                        title: "CPU unavailable",
                        message: cpu.availability.displayText ?? "host_processor_info failed"
                    )
                }
            } else {
                MonitorEmptyState(
                    icon: "cpu",
                    title: "Collecting CPU data",
                    message: "The first tick snapshot establishes the baseline."
                )
            }
        }
    }

    private func loadValue(_ label: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(MonitorFormat.load(value))
                .font(.system(size: 18, weight: .semibold).monospacedDigit())
        }
    }

    private func coreColor(_ usage: Double) -> Color {
        switch usage {
        case ..<25: return Color(red: 0.36, green: 0.70, blue: 0.55)
        case ..<60: return Color(red: 0.85, green: 0.68, blue: 0.30)
        default: return Color(red: 0.90, green: 0.40, blue: 0.36)
        }
    }
}
