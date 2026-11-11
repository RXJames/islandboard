import SwiftUI

struct ThermalSection: View {
    let service: SystemMonitorService

    var body: some View {
        MonitorSectionScaffold(
            "Thermal",
            subtitle: "Thermal pressure from ProcessInfo · temperatures are best-effort SMC/IOReport"
        ) {
            if let thermal = service.thermal {
                HStack(alignment: .top, spacing: 16) {
                    MonitorCard(title: "Thermal State", icon: "thermometer.medium", tint: levelColor(thermal.level)) {
                        HStack(spacing: 16) {
                            ZStack {
                                Circle()
                                    .fill(levelColor(thermal.level).opacity(0.14))
                                    .frame(width: 96, height: 96)
                                Image(systemName: levelIcon(thermal.level))
                                    .font(.system(size: 34, weight: .medium))
                                    .foregroundStyle(levelColor(thermal.level))
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Text(thermal.level.displayName)
                                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                                Text("Public ProcessInfo.thermalState")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("Nominal is the healthy state; serious/critical indicate throttling pressure.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                        }
                    }
                    .frame(maxWidth: .infinity)

                    MonitorCard(title: "Temperatures", icon: "thermometer", tint: MonitorPalette.thermal) {
                        VStack(alignment: .leading, spacing: 9) {
                            ForEach(thermal.sensors) { reading in
                                HStack(spacing: 8) {
                                    Image(systemName: reading.kind.symbolName)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(reading.kind.tint)
                                        .frame(width: 16)
                                    Text(reading.label)
                                        .font(.callout)
                                    Spacer()
                                    Text(MonitorFormat.temperature(reading.celsius))
                                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                                }
                                if reading.id != thermal.sensors.last?.id {
                                    Divider().opacity(0.35)
                                }
                            }
                            Divider().opacity(0.5)
                            MonitorStatRow(
                                label: "Fan",
                                value: thermal.fanRPM.map { "\($0) RPM" } ?? "Not exposed"
                            )
                            Text("SMC and IOReport are private, undocumented interfaces. Missing sensors are listed as “—” rather than estimated.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(width: 320)
                }
            } else {
                MonitorEmptyState(
                    icon: "thermometer",
                    title: "Collecting thermal data",
                    message: "Thermal state is read from ProcessInfo, sensors are best-effort."
                )
            }
        }
    }

    private func levelColor(_ level: ThermalLevel) -> Color {
        switch level {
        case .nominal: return MonitorPalette.memory
        case .fair: return MonitorPalette.disk
        case .serious: return MonitorPalette.thermal
        case .critical: return .red
        case .unknown: return .secondary
        }
    }

    private func levelIcon(_ level: ThermalLevel) -> String {
        switch level {
        case .nominal: return "checkmark.circle.fill"
        case .fair: return "thermometer.medium"
        case .serious: return "exclamationmark.triangle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        case .unknown: return "questionmark.circle"
        }
    }
}
