import BluetoothInspectorKit
import SwiftUI

/// Menu bar commands and keyboard shortcuts.
struct InspectorCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
            Button("Export…") { model.isExportSheetPresented = true }
                .keyboardShortcut("e")
            Button("Export Activity Log as CSV…") { exportLog() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .textEditing) {
            Button("Find…") { model.focusSearch() }
                .keyboardShortcut("f")
        }

        CommandMenu("Bluetooth") {
            Button(model.workspace.isScanning ? "Stop Scan" : "Start Scan") { model.workspace.toggleScan() }
                .keyboardShortcut("r")
            Button(model.workspace.isInquiryRunning ? "Stop Classic Inquiry" : "Start Classic Inquiry") { model.workspace.toggleInquiry() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(!model.workspace.classicAvailable)
            Button("Reload Paired & Recent Classic Devices") { model.workspace.reloadClassicDevices() }
            Button("Find System-Connected Peripherals") { model.workspace.refreshSystemConnectedPeripherals() }
            Divider()
            Button("Connect / Disconnect Selected Device") { model.toggleSelectedConnection() }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(model.selectedDeviceID == nil)
            Button("Read All Readable Characteristics") { model.readAllOnSelectedDevice() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.selectedDevice?.connectionState != .connected)
            Divider()
            Button("Clear Discovered Devices") { model.workspace.clearDiscoveredDevices() }
                .keyboardShortcut(.delete, modifiers: [.command, .option])
        }

        CommandMenu("Console") {
            Button("Clear Console") { model.workspace.log.clear() }
                .keyboardShortcut("k")
            Button(model.workspace.log.isPaused ? "Resume Console" : "Pause Console") { model.workspace.log.isPaused.toggle() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Show Activity Log") { model.section = .activity }
                .keyboardShortcut("l", modifiers: [.command, .shift])
        }

        CommandGroup(after: .sidebar) {
            Divider()
            ForEach(Array(SidebarSection.allCases.enumerated()), id: \.element) { index, section in
                Button(section.title) { model.section = section }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command])
            }
        }
    }

    private func exportLog() {
        let csv = CSVExporter.events(model.workspace.log.allEvents)
        model.present(PendingExport(document: ExportDocument(text: csv, format: .csv), filename: ExportDocument.filename("activity-log", format: .csv)))
    }
}
