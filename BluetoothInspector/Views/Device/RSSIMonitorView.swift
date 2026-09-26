import BluetoothInspectorKit
import Charts
import SwiftUI

/// Live RSSI chart with basic statistics.
struct RSSIMonitorView: View {
    @Environment(AppModel.self) private var model
    let device: InspectedDevice
    @State private var window: RSSIWindow = .oneMinute

    var body: some View {
        // The periodic timeline keeps the time axis moving even when no new
        // samples arrive (e.g. the device went quiet).
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(now: context.date)
        }
        .padding(12)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let _ = device.historyRevision
        let samples = device.rssiHistory.samples(in: window.duration, now: now)
        let stats = RSSIHistory.statistics(for: samples)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Window", selection: $window) {
                    ForEach(RSSIWindow.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Spacer()
                Button("Clear") { device.clearRSSIHistory() }
                    .buttonStyle(.borderless)
            }

            HStack(spacing: 12) {
                statTile("Current", stats.current.map { "\($0)" } ?? "—", unit: "dBm")
                statTile("Average", stats.average.map { String(format: "%.1f", $0) } ?? "—", unit: "dBm")
                statTile("Minimum", stats.minimum.map { "\($0)" } ?? "—", unit: "dBm")
                statTile("Maximum", stats.maximum.map { "\($0)" } ?? "—", unit: "dBm")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Trend").font(.caption).foregroundStyle(.secondary)
                    Label(stats.trend.title, systemImage: stats.trend.symbolName)
                        .font(.headline)
                    if let slope = stats.slope {
                        Text(String(format: "%+.2f dB/s", slope)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            chart(samples: samples, stats: stats, now: now)
                .frame(minHeight: 220)
                .overlay {
                    if samples.isEmpty {
                        ContentUnavailableView("No RSSI Samples", systemImage: "chart.xyaxis.line", description: Text(emptyHint))
                    }
                }

            Label("RSSI is a noisy, relative signal-strength reading. It depends on antenna orientation, obstacles, reflections and the transmitter's power, so it is not a reliable distance measurement.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(stats.count) samples in window · source: \(sourceDescription)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func chart(samples: [RSSISample], stats: RSSIStatistics, now: Date) -> some View {
        // Thin very dense series so a 15-minute window stays responsive.
        let step = max(1, samples.count / 1500)
        let plotted = step == 1 ? samples : samples.enumerated().filter { $0.offset % step == 0 }.map(\.element)
        let low = min(-100, (stats.minimum ?? -100) - 5)
        let high = max(-30, (stats.maximum ?? -30) + 5)
        return Chart {
            ForEach(Array(plotted.enumerated()), id: \.offset) { _, sample in
                LineMark(x: .value("Time", sample.timestamp), y: .value("RSSI", sample.value))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color.accentColor)
                PointMark(x: .value("Time", sample.timestamp), y: .value("RSSI", sample.value))
                    .symbolSize(10)
                    .foregroundStyle(Color.accentColor.opacity(0.6))
            }
            if let average = stats.average {
                RuleMark(y: .value("Average", average))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(.secondary)
                    .annotation(position: .top, alignment: .leading) {
                        Text(String(format: "avg %.1f", average)).font(.caption2).foregroundStyle(.secondary)
                    }
            }
        }
        .chartXScale(domain: now.addingTimeInterval(-window.duration) ... now)
        .chartYScale(domain: low ... high)
        .chartYAxisLabel("dBm")
    }

    private func statTile(_ title: String, _ value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.title2.weight(.semibold)).monospacedDigit()
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu { Button("Copy") { Pasteboard.copy("\(title): \(value) \(unit)") } }
    }

    private var sourceDescription: String {
        if device.transport == .classic { return "IOBluetooth (only while a baseband connection exists)" }
        if device.connectionState == .connected {
            let interval = model.workspace.settings.rssiPollInterval
            return interval > 0 ? "readRSSI every \(String(format: "%g", interval)) s while connected" : "polling disabled in Settings"
        }
        return model.workspace.settings.allowDuplicates ? "advertisements" : "advertisements (duplicates filtered: one sample per scan)"
    }

    private var emptyHint: String {
        if device.transport == .classic { return "Classic RSSI is only reported while the device is connected." }
        if device.connectionState == .connected { return "Waiting for RSSI readings from the connection." }
        return model.workspace.isScanning ? "Waiting for advertisements from this device." : "Start a scan or connect to collect RSSI samples."
    }
}
