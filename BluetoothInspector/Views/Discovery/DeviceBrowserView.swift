import BluetoothInspectorKit
import SwiftUI

/// Device table + inspector, used by Discover, Connected and Saved Devices.
struct DeviceBrowserView: View {
    @Environment(AppModel.self) private var model
    let section: SidebarSection

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                BluetoothStatusBanner()
                DeviceFilterBar(section: section)
                Divider()
                DeviceTableView(section: section)
            }
            .frame(minWidth: 460, idealWidth: 600)

            inspector
                .frame(minWidth: 520, idealWidth: 700, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var inspector: some View {
        if let id = model.selectedDeviceID {
            if let device = model.workspace.device(id) {
                DeviceInspectorView(device: device)
                    .id(id)
            } else if let saved = model.workspace.history[id] {
                SavedDeviceOnlyView(saved: saved)
                    .id(id)
            } else {
                ContentUnavailableView("Device Unavailable", systemImage: "questionmark.circle",
                                       description: Text("This device is no longer in the list."))
            }
        } else {
            emptyState
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch section {
        case .connected:
            ContentUnavailableView {
                Label("No Device Selected", systemImage: "link")
            } description: {
                Text("Connected devices appear here, including peripherals the system or other apps are connected to.")
            } actions: {
                Button("Find System-Connected Peripherals") { model.workspace.refreshSystemConnectedPeripherals() }
            }
        case .saved:
            ContentUnavailableView("No Device Selected", systemImage: "star",
                                   description: Text("Favorites, renamed devices and devices you connected to are remembered here."))
        default:
            ContentUnavailableView {
                Label("No Device Selected", systemImage: "dot.radiowaves.left.and.right")
            } description: {
                Text("Start a scan (⌘R) to discover BLE devices, or run a Classic inquiry (⇧⌘I). Select a device to inspect it.")
            } actions: {
                if !model.workspace.isScanning {
                    Button("Start Scan") { model.workspace.startScan() }
                        .buttonStyle(.glassProminent)
                        .disabled(model.workspace.powerState != .poweredOn)
                }
            }
        }
    }
}

struct DeviceFilterBar: View {
    @Environment(AppModel.self) private var model
    let section: SidebarSection
    @State private var rssiEnabled = false
    @State private var rssiThreshold = -80.0

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 10) {
            Picker("Transport", selection: $model.filter.transport) {
                ForEach(TransportFilter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Filter by Bluetooth transport. “Dual-mode?” shows name-matched BLE/Classic pairs (heuristic).")

            Picker("Name", selection: $model.filter.name) {
                ForEach(NameFilter.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()

            Toggle(isOn: $rssiEnabled) {
                Image(systemName: "cellularbars")
            }
            .toggleStyle(.button)
            .help("Hide devices weaker than the RSSI threshold")
            if rssiEnabled {
                Slider(value: $rssiThreshold, in: -100 ... -30, step: 1)
                    .frame(width: 90)
                Text("≥ \(Int(rssiThreshold)) dBm")
                    .monospacedDigit()
                    .font(.caption)
                    .frame(width: 62, alignment: .leading)
            }

            TextField("Service UUID", text: $model.filter.serviceUUID)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 130)
                .help("Only devices advertising or exposing this service (e.g. 180D or “Heart Rate”)")

            Toggle(isOn: $model.filter.favoritesOnly) {
                Image(systemName: model.filter.favoritesOnly ? "star.fill" : "star")
            }
            .toggleStyle(.button)
            .help("Favorites only")

            Spacer(minLength: 0)

            Text("\(model.items(for: section).count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help("Devices shown")

            if section == .discover {
                Button {
                    model.workspace.clearDiscoveredDevices()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Clear discovered devices (connected devices are kept) (⌥⌘⌫)")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .onChange(of: rssiEnabled) { applyRSSI() }
        .onChange(of: rssiThreshold) { applyRSSI() }
        .onAppear {
            rssiEnabled = model.filter.minimumRSSI != nil
            rssiThreshold = Double(model.filter.minimumRSSI ?? -80)
        }
    }

    private func applyRSSI() {
        model.filter.minimumRSSI = rssiEnabled ? Int(rssiThreshold) : nil
    }
}
