import BluetoothInspectorKit
import SwiftUI

struct DeviceTableView: View {
    @Environment(AppModel.self) private var model
    let section: SidebarSection

    var body: some View {
        @Bindable var model = model
        let items = model.items(for: section)
        Table(items, selection: $model.selectedDeviceID, sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \.nameSortValue) { item in
                HStack(spacing: 6) {
                    Image(systemName: icon(for: item))
                        .foregroundStyle(item.isLive ? Color.accentColor : .secondary)
                        .frame(width: 16)
                    Text(item.displayName)
                        .foregroundStyle(item.hasName || item.displayName != "Unnamed" ? .primary : .secondary)
                        .lineLimit(1)
                    if item.isFavorite {
                        Image(systemName: "star.fill").foregroundStyle(.yellow).imageScale(.small)
                    }
                }
                .opacity(item.isLive ? 1 : 0.6)
            }
            .width(min: 140, ideal: 190)

            TableColumn("Type") { item in
                TransportBadge(transport: item.transport, dualModeHint: item.dualModeHint)
            }
            .width(min: 60, ideal: 78)

            TableColumn("RSSI", value: \.rssiSortValue) { item in
                RSSIIndicator(rssi: item.rssi)
            }
            .width(min: 80, ideal: 92)

            TableColumn("State") { item in
                ConnectionBadge(state: item.connectionState, systemConnected: item.isSystemConnected)
            }
            .width(min: 80, ideal: 100)

            TableColumn("Manufacturer") { item in
                Text(item.manufacturer ?? "—")
                    .foregroundStyle(item.manufacturer == nil ? .secondary : .primary)
                    .lineLimit(1)
            }
            .width(min: 90, ideal: 150)

            TableColumn("Identifier", value: \.identifierString) { item in
                Text(item.identifierString)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 90, ideal: 170)

            TableColumn("Last Seen", value: \.lastSeenSortValue) { item in
                Text(DisplayFormatting.time(item.lastSeen))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 64, ideal: 74)
        }
        .contextMenu(forSelectionType: DeviceID.self) { ids in
            if let id = ids.first {
                DeviceContextMenu(id: id)
            }
        } primaryAction: { ids in
            // Double-click connects (BLE) or queries SDP services (Classic).
            guard let id = ids.first else { return }
            if case .classic = id {
                model.workspace.performSDPQuery(id)
            } else {
                model.workspace.toggleConnection(id)
            }
        }
        .overlay {
            if items.isEmpty {
                emptyOverlay
            }
        }
    }

    private func icon(for item: DeviceListItem) -> String {
        if item.transport == .classic {
            return model.workspace.device(item.id)?.classic?.classOfDevice?.symbolName ?? "antenna.radiowaves.left.and.right"
        }
        if item.connectionState == .connected { return "link.circle.fill" }
        return item.isConnectable == false ? "wave.3.right" : "dot.radiowaves.right"
    }

    @ViewBuilder
    private var emptyOverlay: some View {
        let workspace = model.workspace
        if !model.searchText.isEmpty || model.filter.isActive {
            ContentUnavailableView.search(text: model.searchText)
        } else {
            switch section {
            case .connected:
                ContentUnavailableView("Nothing Connected", systemImage: "link",
                                       description: Text("Double-click a connectable BLE device in Discover to connect."))
            case .saved:
                ContentUnavailableView("No Saved Devices", systemImage: "star",
                                       description: Text("Favorite or connect to a device to remember it."))
            default:
                if workspace.isScanning {
                    ContentUnavailableView {
                        ProgressView()
                    } description: {
                        Text("Scanning for advertisements…")
                    }
                } else {
                    ContentUnavailableView("No Devices", systemImage: "dot.radiowaves.left.and.right",
                                           description: Text("Press ⌘R to scan for BLE devices."))
                }
            }
        }
    }
}

/// Context menu shared by device tables.
struct DeviceContextMenu: View {
    @Environment(AppModel.self) private var model
    let id: DeviceID

    var body: some View {
        let workspace = model.workspace
        let device = workspace.device(id)
        let saved = workspace.history[id]
        if case .lowEnergy = id, let device {
            Button(device.connectionState == .disconnected ? "Connect" : "Disconnect") { workspace.toggleConnection(id) }
                .disabled(device.advertisement.isConnectable == false && device.connectionState == .disconnected && !device.isSystemConnected)
        }
        if case .classic = id {
            Button("Query SDP Services") { workspace.performSDPQuery(id) }
        }
        Divider()
        Button("Copy Identifier") { Pasteboard.copy(id.identifierString) }
        if let name = device?.name ?? saved?.name {
            Button("Copy Name") { Pasteboard.copy(name) }
        }
        if let device {
            Button("Copy Service UUIDs") {
                Pasteboard.copy(device.knownServiceUUIDs.map(\.displayName).joined(separator: "\n"))
            }
            if let data = device.advertisement.manufacturerData {
                Button("Copy Manufacturer Data (Hex)") { Pasteboard.copy(data.hexString) }
            }
        }
        Divider()
        Button(saved?.isFavorite == true ? "Remove from Favorites" : "Add to Favorites") {
            workspace.setFavorite(id, !(saved?.isFavorite ?? false))
        }
        if saved != nil {
            Button("Forget Saved Device", role: .destructive) { workspace.forget(id) }
        }
    }
}
