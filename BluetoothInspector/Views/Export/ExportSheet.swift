import BluetoothInspectorKit
import SwiftUI

/// Chooses what to export and in which format, then hands the file to the save panel.
struct ExportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var scope: Scope = .selectedDevice
    @State private var format: ExportFormat = .json

    enum Scope: String, CaseIterable, Identifiable {
        case selectedDevice
        case allDevices
        case activityLog

        var id: String { rawValue }
        var title: String {
            switch self {
            case .selectedDevice: "Selected Device"
            case .allDevices: "All Devices (Session)"
            case .activityLog: "Activity Log"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export").font(.title2.weight(.semibold))
            Form {
                Picker("What", selection: $scope) {
                    ForEach(Scope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                Picker("Format", selection: $format) {
                    ForEach(ExportFormat.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if scope == .selectedDevice && model.selectedDevice == nil {
                Label("Select a device in Discover, Connected or Saved Devices first.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") { export() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(scope == .selectedDevice && model.selectedDevice == nil)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            if model.selectedDevice == nil { scope = .allDevices }
        }
    }

    private var description: String {
        switch (scope, format) {
        case (.selectedDevice, .json): "Device summary, advertisement, services, characteristics with values and decodes, descriptors, value history, RSSI samples, SDP records and events."
        case (.selectedDevice, .csv): "The device's value history (reads, notifications and writes), one row per value."
        case (.selectedDevice, .text): "A human-readable diagnostic report for the device."
        case (.allDevices, .json): "Every device in this session plus diagnostics and the full activity log."
        case (.allDevices, .csv): "One row per device: identifier, name, transport, RSSI, manufacturer, services."
        case (.allDevices, .text): "Diagnostic reports for every device, one after another."
        case (.activityLog, .json): "Every retained event with timestamps, UUIDs and payload hex."
        case (.activityLog, .csv): "Every retained event, one row per event."
        case (.activityLog, .text): "The console as plain text."
        }
    }

    private func export() {
        let builder = model.exportBuilder
        let workspace = model.workspace
        do {
            let document: ExportDocument
            let name: String
            switch (scope, format) {
            case (.selectedDevice, _):
                guard let device = model.selectedDevice else { return }
                name = device.displayName
                switch format {
                case .json: document = ExportDocument(data: try builder.json(builder.deviceExport(device)), format: .json)
                case .csv: document = ExportDocument(text: CSVExporter.values(device.valueRecords), format: .csv)
                case .text: document = ExportDocument(text: builder.textReport(for: device), format: .text)
                }
            case (.allDevices, .json):
                name = "session"
                document = ExportDocument(data: try builder.json(builder.sessionExport()), format: .json)
            case (.allDevices, .csv):
                name = "devices"
                workspace.refreshDeviceListIfNeeded(force: true)
                document = ExportDocument(text: CSVExporter.devices(workspace.deviceList), format: .csv)
            case (.allDevices, .text):
                name = "session-report"
                let reports = workspace.devices.values.sorted { $0.id < $1.id }.map { builder.textReport(for: $0) }
                document = ExportDocument(text: reports.joined(separator: "\n\n" + String(repeating: "#", count: 72) + "\n\n"), format: .text)
            case (.activityLog, .json):
                name = "activity-log"
                document = ExportDocument(data: try ExportCoding.jsonEncoder().encode(workspace.log.allEvents.map(EventExport.init)), format: .json)
            case (.activityLog, .csv):
                name = "activity-log"
                document = ExportDocument(text: CSVExporter.events(workspace.log.allEvents), format: .csv)
            case (.activityLog, .text):
                name = "activity-log"
                document = ExportDocument(text: EventLog.consoleText(workspace.log.allEvents) + "\n", format: .text)
            }
            dismiss()
            model.present(PendingExport(document: document, filename: ExportDocument.filename(name, format: format)))
        } catch {
            model.errorMessage = "Export failed: \(error.localizedDescription)"
        }
    }
}
