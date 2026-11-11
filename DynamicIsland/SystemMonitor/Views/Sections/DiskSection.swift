import SwiftUI

struct DiskSection: View {
    let service: SystemMonitorService

    var body: some View {
        MonitorSectionScaffold(
            "Disk",
            subtitle: "Capacity from mounted volumes · I/O from IOBlockStorageDriver"
        ) {
            if let disk = service.disk {
                MonitorCard(
                    title: "Volumes",
                    icon: "internaldrive",
                    tint: MonitorPalette.disk,
                    subtitle: "\(disk.volumes.count) mounted volumes"
                ) {
                    if disk.volumes.isEmpty {
                        MonitorEmptyState(
                            icon: "externaldrive.badge.questionmark",
                            title: "No volumes",
                            message: disk.availability.displayText ?? "No mounted volume was reported."
                        )
                    } else {
                        VStack(spacing: 14) {
                            ForEach(disk.volumes) { volume in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 8) {
                                        Image(systemName: volume.isRemovable ? "externaldrive" : (volume.isRoot ? "internaldrive.fill" : "internaldrive"))
                                            .foregroundStyle(MonitorPalette.disk)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(volume.name)
                                                .font(.system(size: 13, weight: .medium))
                                            Text(volume.mountPoint)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text(MonitorFormat.percent(volume.usagePercent, digits: 1))
                                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                                    }
                                    MonitorProgressBar(
                                        fraction: volume.usagePercent / 100,
                                        tint: MonitorPalette.disk,
                                        height: 8
                                    )
                                    HStack {
                                        Text("\(MonitorFormat.bytes(volume.usedBytes)) used")
                                        Spacer()
                                        Text("\(MonitorFormat.bytes(volume.freeBytes)) free of \(MonitorFormat.bytes(volume.totalBytes))")
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                HStack(alignment: .top, spacing: 16) {
                    MonitorCard(title: "I/O Activity", icon: "arrow.left.arrow.right", tint: MonitorPalette.disk) {
                        HStack(spacing: 24) {
                            ioValue("Read", rate: disk.readBytesPerSecond, color: MonitorPalette.network)
                            ioValue("Write", rate: disk.writeBytesPerSecond, color: MonitorPalette.disk)
                            Spacer()
                        }
                        if disk.ioAvailability.isAvailable {
                            MonitorHistoryChart(
                                primary: disk.historyRead,
                                secondary: disk.historyWrite,
                                primaryTint: MonitorPalette.network,
                                secondaryTint: MonitorPalette.disk,
                                primaryLabel: "Read",
                                secondaryLabel: "Write",
                                height: 110
                            )
                        } else {
                            MonitorEmptyState(
                                icon: "externaldrive.badge.xmark",
                                title: "I/O counters unavailable",
                                message: disk.ioAvailability.displayText ?? "IOBlockStorageDriver did not expose counters."
                            )
                        }
                    }
                    .frame(maxWidth: .infinity)

                    MonitorCard(title: "Cumulative I/O", icon: "sum", tint: MonitorPalette.disk) {
                        MonitorStatRow(label: "Read since boot", value: MonitorFormat.bytes(disk.totalReadBytes), tint: MonitorPalette.network)
                        Divider().opacity(0.5)
                        MonitorStatRow(label: "Written since boot", value: MonitorFormat.bytes(disk.totalWrittenBytes), tint: MonitorPalette.disk)
                        Divider().opacity(0.5)
                        HStack {
                            MonitorAvailabilityBadge(availability: disk.ioAvailability)
                            Spacer()
                        }
                    }
                    .frame(width: 260)
                }
            } else {
                MonitorEmptyState(
                    icon: "internaldrive",
                    title: "Collecting disk data",
                    message: "Capacity is available immediately; I/O appears after the second sample."
                )
            }
        }
    }

    private func ioValue(_ label: String, rate: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(MonitorFormat.rate(rate))
                .font(.system(size: 18, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(color)
        }
    }
}
