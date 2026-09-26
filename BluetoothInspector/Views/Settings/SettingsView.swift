import BluetoothInspectorKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var importingSIG = false
    @State private var confirmForgetAll = false

    var body: some View {
        let workspace = model.workspace
        Form {
            Section {
                Toggle("Report every advertisement (allow duplicates)", isOn: model.settingBinding(\.allowDuplicates))
                TextField("Hardware service filter", text: model.settingBinding(\.scanServiceFilter), prompt: Text("e.g. 180D, 180F"))
            } header: {
                Text("BLE Scanning")
            } footer: {
                Text("Duplicates are needed for live RSSI and advertisement-change tracking. The hardware filter only matches services that appear in the advertisement itself; leave it empty to see everything.")
            }

            Section {
                LabeledContent("Connection timeout") {
                    Stepper(value: model.settingBinding(\.connectionTimeout), in: 5...120, step: 5) {
                        Text("\(Int(workspace.settings.connectionTimeout)) s").monospacedDigit()
                    }
                }
                LabeledContent("RSSI polling while connected") {
                    Picker("RSSI polling", selection: model.settingBinding(\.rssiPollInterval)) {
                        Text("Off").tag(0.0)
                        Text("0.5 s").tag(0.5)
                        Text("1 s").tag(1.0)
                        Text("2 s").tag(2.0)
                        Text("5 s").tag(5.0)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Toggle("Read descriptors after discovery", isOn: model.settingBinding(\.autoReadDescriptors))
                Toggle("Read all readable characteristics after discovery", isOn: model.settingBinding(\.autoReadCharacteristics))
                TextField("Services for system-connected lookup", text: model.settingBinding(\.systemConnectedServiceUUIDs))
            } header: {
                Text("Connections & GATT")
            } footer: {
                Text("CoreBluetooth never times out a connection attempt on its own; Bluetooth Inspector cancels it after the timeout. Reading encrypted values makes macOS show a pairing prompt. Finding system-connected peripherals requires naming at least one service they expose.")
            }

            Section {
                Toggle("Confirm before every write", isOn: model.settingBinding(\.confirmWrites))
            } header: {
                Text("Writes")
            } footer: {
                Text("Bluetooth Inspector never writes to a device on its own. Every write requires pressing Write.")
            }

            Section("Activity Log") {
                Picker("Keep newest", selection: model.settingBinding(\.logCapacity)) {
                    ForEach([1_000, 5_000, 10_000, 25_000, 50_000], id: \.self) { Text("\($0.formatted()) events").tag($0) }
                }
                Toggle("Log advertisement changes", isOn: model.settingBinding(\.logAdvertisementChanges))
                Toggle("Log every RSSI reading", isOn: model.settingBinding(\.logRSSIReadings))
            }

            Section {
                Picker("Remember", selection: model.settingBinding(\.historyMode)) {
                    ForEach(HistoryMode.allCases) { Text($0.title).tag($0) }
                }
                Button("Forget All Saved Devices…", role: .destructive) { confirmForgetAll = true }
                    .disabled(workspace.history.devices.isEmpty)
            } header: {
                Text("Saved Devices")
            } footer: {
                Text("Saved devices are stored only on this Mac. Favorites, local names and notes are always saved.")
            }

            Section {
                LabeledContent("Inquiry duration") {
                    Stepper(value: model.settingBinding(\.classicInquiryDuration), in: 5...60, step: 5) {
                        Text("\(Int(workspace.settings.classicInquiryDuration)) s").monospacedDigit()
                    }
                }
            } header: {
                Text("Bluetooth Classic")
            }

            Section {
                LabeledContent("Built-in names", value: "Services, characteristics, descriptors, member UUIDs, SDP classes, common companies")
                LabeledContent("Extra entries loaded", value: "\(AssignedNumbers.extensionEntryCount)")
                Button("Load SIG Database JSON…") { importingSIG = true }
            } header: {
                Text("Bluetooth SIG Database")
            } footer: {
                Text("Generate a complete database (for example every company identifier) with Scripts/generate_sig_tables.py --full-json.")
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $importingSIG, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result { model.loadSIGExtension(from: url) }
        }
        .confirmationDialog("Forget all saved devices?", isPresented: $confirmForgetAll) {
            Button("Forget All", role: .destructive) { workspace.forgetAllSavedDevices() }
        } message: {
            Text("Removes every saved device, including favorites, local names and notes.")
        }
    }
}
