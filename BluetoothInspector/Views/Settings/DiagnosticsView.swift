import BluetoothInspectorKit
import SwiftUI

struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @State private var copied = false

    var body: some View {
        let workspace = model.workspace
        let builder = model.exportBuilder
        Form {
            Section {
                HStack {
                    Button {
                        Pasteboard.copy(builder.diagnosticsText())
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy Diagnostics", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.glassProminent)
                    Button("Find System-Connected Peripherals") { workspace.refreshSystemConnectedPeripherals() }
                    Button("Reload Classic Devices") { workspace.reloadClassicDevices() }
                    Spacer()
                }
            }

            Section("App & System") {
                InfoRow("App Version", model.context.appVersion)
                InfoRow("macOS", model.context.operatingSystem)
                InfoRow("Hardware", model.context.hardwareModel ?? "Unknown")
            }

            Section("Bluetooth Low Energy (CoreBluetooth)") {
                InfoRow("Power State", workspace.powerState.title)
                InfoRow("Authorization", workspace.authorization.title)
                if let guidance = workspace.powerState.guidance {
                    Text(guidance).font(.callout).foregroundStyle(.orange)
                }
                InfoRow("Scanner", workspace.scannerState.title)
                if let started = workspace.scanStartedAt {
                    InfoRow("Scanning Since", DisplayFormatting.dateTime(started))
                }
                InfoRow("Scan Options", builder.diagnostics()["Scan Options"] ?? "")
                InfoRow("Devices Known", "\(workspace.devices.count)")
            }

            Section("Connected Peripherals") {
                if workspace.connectedDevices.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                }
                ForEach(workspace.connectedDevices) { device in
                    HStack {
                        TransportBadge(transport: device.transport)
                        Text(device.displayName)
                        Spacer()
                        Text(device.id.identifierString)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        ConnectionBadge(state: device.connectionState, systemConnected: device.isSystemConnected)
                    }
                }
            }

            Section("Bluetooth Classic (IOBluetooth)") {
                InfoRow("Available", workspace.classicAvailable ? "Yes" : "No")
                InfoRow("Controller Address", workspace.hostController.address ?? "Unavailable", monospaced: true)
                InfoRow("Controller Name", workspace.hostController.name ?? "Unavailable")
                InfoRow("Controller Power", workspace.hostController.isPoweredOn.map { $0 ? "On" : "Off" } ?? "Unknown")
                if let cod = workspace.hostController.classOfDevice {
                    InfoRow("Class of Device", "\(cod.hexString) \(cod.summary)")
                }
                InfoRow("Inquiry", workspace.isInquiryRunning ? "Running" : "Idle")
            }

            Section("Activity") {
                InfoRow("Events Recorded", "\(workspace.log.totalCount)")
                InfoRow("Events Retained", "\(workspace.log.allEvents.count) of \(workspace.log.capacity)")
                InfoRow("Errors", "\(workspace.log.errorCount)")
                InfoRow("Saved Devices", "\(workspace.history.devices.count)")
                if let error = workspace.historyError {
                    Text(error).foregroundStyle(.red)
                }
            }

            Section("macOS Bluetooth Limitations") {
                LimitationsNote(transport: .lowEnergy)
                LimitationsNote(transport: .classic)
                Label("BLE and Classic identities cannot be linked through public APIs, so dual-mode is shown only as a name-match heuristic.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: workspace.log.totalCount) { copied = false }
    }
}
