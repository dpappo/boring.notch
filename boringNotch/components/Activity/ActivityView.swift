//
//  ActivityView.swift
//  boringNotch
//

import SwiftUI

struct ActivityView: View {
    @ObservedObject private var activity = SystemActivityManager.shared

    var body: some View {
        GeometryReader { geo in
            let compactMode = geo.size.width < 520
            let columns = Array(
                repeating: GridItem(.flexible(minimum: 120), spacing: 6, alignment: .top),
                count: compactMode ? 2 : 3
            )

            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                    metricCard(
                        title: "CPU",
                        icon: "cpu",
                        valueText: String(format: "%.0f%%", activity.cpuTotalPercent),
                        percent: activity.cpuTotalPercent,
                        rows: activity.topCPU
                    )

                    metricCard(
                        title: "Memory",
                        icon: "memorychip",
                        valueText: String(format: "%.0f%%", activity.memoryUsedPercent),
                        percent: activity.memoryUsedPercent,
                        rows: activity.topMemory,
                        subtitle: memorySubtitle
                    )

                    gpuCard
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear { activity.startPolling() }
        .onDisappear { activity.stopPolling() }
    }

    private var gpuCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: "square.3.layers.3d.top.filled")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("GPU")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if activity.gpuMetricsAvailable, let gpuTotalPercent = activity.gpuTotalPercent {
                    Text(String(format: "%.0f%%", gpuTotalPercent))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                } else {
                    Text("—")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            if activity.gpuMetricsAvailable, let gpuTotalPercent = activity.gpuTotalPercent {
                gaugeBar(percent: gpuTotalPercent)
            } else {
                Text("Unavailable on this Mac")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            ForEach(activity.topGPU.prefix(3)) { row in
                processRow(name: row.name, detail: row.detail)
            }

            if let gpuDeviceName = activity.gpuDeviceName {
                Text(gpuDeviceName)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(cardBackground)
    }

    private func metricCard(
        title: String,
        icon: String,
        valueText: String,
        percent: Double,
        rows: [ActivityProcessRow],
        subtitle: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(valueText)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
            }

            gaugeBar(percent: percent)

            ForEach(rows.prefix(3)) { row in
                processRow(name: row.name, detail: row.detail)
            }

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(nsColor: .secondarySystemFill).opacity(0.35))
    }

    private func gaugeBar(percent: Double) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            let clamped = min(max(percent / 100.0, 0), 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.gray.opacity(0.25))
                    .frame(height: 4)
                Capsule()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: width * clamped, height: 4)
            }
        }
        .frame(height: 4)
    }

    private func processRow(name: String, detail: String) -> some View {
        HStack(spacing: 4) {
            Text(name)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(detail)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var memorySubtitle: String {
        let bytes = activity.physicalMemoryBytes
        guard bytes > 0 else { return "" }
        let gb = Double(bytes) / 1024 / 1024 / 1024
        return String(format: "%.0f GB total", gb)
    }
}

#Preview {
    ActivityView()
        .frame(width: 420, height: 220)
        .background(Color.black)
}
