import BluetoothInspectorKit
import SwiftUI

enum InspectorTab: String, CaseIterable, Identifiable {
    case overview
    case advertisement
    case gatt
    case values
    case sdp
    case rssi
    case raw
    case notes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .advertisement: "Advertisement"
        case .gatt: "GATT"
        case .values: "Values"
        case .sdp: "SDP Services"
        case .rssi: "RSSI"
        case .raw: "Raw Data"
        case .notes: "Notes"
        }
    }

    var symbolName: String {
        switch self {
        case .overview: "info.circle"
        case .advertisement: "megaphone"
        case .gatt: "list.bullet.indent"
        case .values: "bell"
        case .sdp: "list.bullet.rectangle"
        case .rssi: "chart.xyaxis.line"
        case .raw: "number"
        case .notes: "note.text"
        }
    }

    static func tabs(for transport: BluetoothTransport) -> [InspectorTab] {
        switch transport {
        case .lowEnergy: [.overview, .advertisement, .gatt, .values, .rssi, .raw, .notes]
        case .classic: [.overview, .sdp, .rssi, .notes]
        }
    }
}

struct DeviceInspectorView: View {
    @Environment(AppModel.self) private var model
    let device: InspectedDevice
    @State private var tab: InspectorTab = .overview

    var body: some View {
        VStack(spacing: 0) {
            DeviceHeaderView(device: device)
            Picker("Section", selection: $tab) {
                ForEach(InspectorTab.tabs(for: device.transport)) { tab in
                    Label(tab.title, systemImage: tab.symbolName).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: device.connectionState) { _, state in
            // Jump to the GATT tree when a connection the user started completes.
            if state == .connected, tab == .overview { tab = .gatt }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .overview: OverviewTab(device: device)
        case .advertisement: AdvertisementTab(device: device)
        case .gatt: GATTExplorerView(device: device)
        case .values: ValueHistoryView(device: device)
        case .sdp: ClassicServicesView(device: device)
        case .rssi: RSSIMonitorView(device: device)
        case .raw: RawDataView(device: device)
        case .notes: DeviceNotesView(id: device.id)
        }
    }
}

struct DeviceHeaderView: View {
    @Environment(AppModel.self) private var model
    let device: InspectedDevice

    var body: some View {
        let workspace = model.workspace
        let saved = workspace.history[device.id]
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: device.transport == .classic
                  ? (device.classic?.classOfDevice?.symbolName ?? "antenna.radiowaves.left.and.right")
                  : "dot.radiowaves.left.and.right")
                .font(.system(size: 28))
                .foregroundStyle(Color.accentColor)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(saved?.customName ?? device.displayName)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                        .textSelection(.enabled)
                    Button {
                        workspace.setFavorite(device.id, !(saved?.isFavorite ?? false))
                    } label: {
                        Image(systemName: saved?.isFavorite == true ? "star.fill" : "star")
                            .foregroundStyle(saved?.isFavorite == true ? Color.yellow : Color.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(saved?.isFavorite == true ? "Remove from favorites" : "Add to favorites")
                }
                HStack(spacing: 8) {
                    TransportBadge(transport: device.transport, dualModeHint: device.dualModeHint)
                    ConnectionBadge(state: device.connectionState == .disconnected && device.classic?.isConnected == true ? .connected : device.connectionState,
                                    systemConnected: device.isSystemConnected)
                    RSSIIndicator(rssi: device.rssi)
                    Text(device.id.identifierString)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    CopyButton(text: device.id.identifierString, help: "Copy device identifier")
                }
                if let error = device.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }

            Spacer()

            actions
        }
        .padding(12)
    }

    @ViewBuilder
    private var actions: some View {
        let workspace = model.workspace
        switch device.transport {
        case .lowEnergy:
            switch device.connectionState {
            case .disconnected:
                Button {
                    workspace.connect(device.id)
                } label: {
                    Label("Connect", systemImage: "link")
                }
                .buttonStyle(.glassProminent)
                .disabled(workspace.powerState != .poweredOn)
                .help(device.advertisement.isConnectable == false
                      ? "The device advertises as non-connectable; connecting will likely fail"
                      : "Connect and discover GATT services (⌘↩)")
            case .connecting:
                HStack {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { workspace.disconnect(device.id) }
                }
            case .connected:
                Button {
                    workspace.disconnect(device.id)
                } label: {
                    Label("Disconnect", systemImage: "link.badge.plus")
                        .symbolRenderingMode(.hierarchical)
                }
                .help("Disconnect (⌘↩)")
            case .disconnecting:
                ProgressView().controlSize(.small)
            }
        case .classic:
            Button {
                workspace.performSDPQuery(device.id)
            } label: {
                Label("Query Services", systemImage: "magnifyingglass")
            }
            .buttonStyle(.glassProminent)
            .disabled(device.isSDPQueryRunning)
            .help("Run an SDP query to list the device's Classic services")
        }
    }
}

/// Shown for saved devices that have not been seen in this session.
struct SavedDeviceOnlyView: View {
    let saved: SavedDevice

    var body: some View {
        VStack(spacing: 0) {
            ContentUnavailableView {
                Label(saved.displayName, systemImage: saved.isFavorite ? "star.fill" : "clock.arrow.circlepath")
            } description: {
                Text("Not seen in this session. Last seen \(DisplayFormatting.dateTime(saved.lastSeen)). Scan (BLE) or run an inquiry (Classic) to find it again.")
            }
            .frame(maxHeight: 220)
            Divider()
            DeviceNotesView(id: saved.id)
        }
    }
}
