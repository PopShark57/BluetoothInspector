import BluetoothInspectorKit
import SwiftUI

/// Hierarchical Service → Characteristic → Descriptor browser with a detail pane.
struct GATTExplorerView: View {
    @Environment(AppModel.self) private var model
    let device: InspectedDevice
    /// Selected outline row (`Node.id`).
    @State private var selection: String?

    /// Row model for the outline.
    struct Node: Identifiable, Hashable {
        enum Kind: Hashable { case service(isPrimary: Bool), includedService, characteristic, descriptor }
        /// Row identity. Included services appear under several parents, so
        /// rows cannot simply use the attribute's ID.
        let id: String
        /// The attribute this row represents.
        let target: GATTNodeID
        let kind: Kind
        let uuid: BluetoothUUID
        let title: String
        let properties: GATTProperties
        let isNotifying: Bool
        let hasError: Bool
        let children: [Node]?
    }

    private var nodes: [Node] {
        device.gatt.services.map { service in
            var children: [Node] = service.includedServiceIDs.compactMap { includedID in
                device.gatt.service(includedID).map {
                    Node(id: "inc-\(service.id)-\(includedID)", target: includedID, kind: .includedService, uuid: $0.uuid, title: "Includes \($0.name)",
                         properties: [], isNotifying: false, hasError: false, children: nil)
                }
            }
            children += service.characteristics.map { characteristic in
                let descriptors = characteristic.descriptors.map { descriptor in
                    Node(id: descriptor.id.description, target: descriptor.id, kind: .descriptor, uuid: descriptor.uuid, title: descriptor.name,
                         properties: [], isNotifying: false, hasError: descriptor.lastError != nil, children: nil)
                }
                return Node(id: characteristic.id.description, target: characteristic.id, kind: .characteristic, uuid: characteristic.uuid,
                            title: characteristic.userDescription.map { "\(characteristic.name) — \($0)" } ?? characteristic.name,
                            properties: characteristic.properties, isNotifying: characteristic.isNotifying,
                            hasError: characteristic.lastError != nil, children: descriptors.isEmpty ? nil : descriptors)
            }
            return Node(id: service.id.description, target: service.id, kind: .service(isPrimary: service.isPrimary), uuid: service.uuid, title: service.name,
                        properties: [], isNotifying: false, hasError: service.lastError != nil,
                        children: children.isEmpty ? nil : children)
        }
    }

    var body: some View {
        if device.gatt.isEmpty {
            emptyState
        } else {
            HSplitView {
                VStack(spacing: 0) {
                    toolbar
                    Divider()
                    List(nodes, children: \.children, selection: $selection) { node in
                        GATTNodeRow(node: node)
                            .contextMenu { nodeMenu(node) }
                    }
                    .listStyle(.sidebar)
                }
                .frame(minWidth: 260, idealWidth: 330)

                detail
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text("\(device.gatt.services.count) services · \(device.gatt.characteristicCount) characteristics")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if device.gatt.serviceDiscovery == .discovering {
                ProgressView().controlSize(.small)
            }
            Button {
                model.workspace.readAll(on: device.id)
            } label: {
                Image(systemName: "arrow.down.doc")
            }
            .help("Read all readable characteristics (⇧⌘R). Reading encrypted values can trigger a pairing prompt.")
            .disabled(device.connectionState != .connected)
            Button {
                model.workspace.discoverServices(device.id)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Rediscover services")
            .disabled(device.connectionState != .connected)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var detail: some View {
        if let selection = selectedTarget {
            if let characteristic = device.gatt.characteristic(selection) {
                CharacteristicDetailView(device: device, characteristicID: characteristic.id)
                    .id(characteristic.id)
            } else if let service = device.gatt.service(selection) {
                ServiceDetailView(device: device, service: service)
            } else if let (characteristic, descriptor) = device.gatt.descriptor(selection) {
                DescriptorDetailView(device: device, characteristic: characteristic, descriptor: descriptor)
            } else {
                ContentUnavailableView("Select an Attribute", systemImage: "list.bullet.indent")
            }
        } else {
            ContentUnavailableView("Select an Attribute", systemImage: "list.bullet.indent",
                                   description: Text("Choose a service, characteristic or descriptor to inspect it."))
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch device.connectionState {
        case .connected:
            if device.gatt.serviceDiscovery == .failed {
                ContentUnavailableView {
                    Label("Service Discovery Failed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(device.gatt.lastError ?? "Unknown error")
                } actions: {
                    Button("Retry") { model.workspace.discoverServices(device.id) }
                }
            } else if device.gatt.serviceDiscovery == .complete {
                ContentUnavailableView("No Visible Services", systemImage: "eye.slash",
                                       description: Text("The device exposes no services to apps. macOS reserves some services (for example HID 0x1812) for the system."))
            } else {
                ContentUnavailableView {
                    ProgressView()
                } description: {
                    Text("Discovering services…")
                }
            }
        case .connecting:
            ContentUnavailableView {
                ProgressView()
            } description: {
                Text("Connecting…")
            }
        default:
            ContentUnavailableView {
                Label("Not Connected", systemImage: "link")
            } description: {
                Text(device.advertisement.isConnectable == false
                     ? "This device advertises as non-connectable, so its GATT database is not reachable."
                     : "Connect to discover primary and secondary services, characteristics and descriptors.")
            } actions: {
                Button("Connect") { model.workspace.connect(device.id) }
                    .buttonStyle(.glassProminent)
                    .disabled(model.workspace.powerState != .poweredOn)
            }
        }
    }

    @ViewBuilder
    private func nodeMenu(_ node: Node) -> some View {
        Button("Copy UUID") { Pasteboard.copy(node.uuid.uuidString) }
        Button("Copy Short UUID") { Pasteboard.copy(node.uuid.shortString) }
        Button("Copy Name") { Pasteboard.copy("\(node.uuid.shortString) \(node.title)") }
        if node.kind == .characteristic, let characteristic = device.gatt.characteristic(node.target) {
            if let value = characteristic.value {
                Button("Copy Value (Hex)") { Pasteboard.copy(value.hexString) }
            }
            Divider()
            if characteristic.properties.isReadable {
                Button("Read") { model.workspace.read(characteristic: node.target, on: device.id) }
            }
            if characteristic.properties.canSubscribe {
                Button(characteristic.isNotifying ? "Unsubscribe" : "Subscribe") {
                    model.workspace.setNotify(!characteristic.isNotifying, for: node.target, on: device.id)
                }
            }
        }
        if case .service = node.kind, let service = device.gatt.service(node.target) {
            Button("Copy Service Information") { Pasteboard.copy(serviceSummary(service)) }
        }
    }

    /// Resolves the selected row to the attribute it represents.
    private var selectedTarget: GATTNodeID? {
        guard let selection else { return nil }
        func find(_ nodes: [Node]) -> GATTNodeID? {
            for node in nodes {
                if node.id == selection { return node.target }
                if let found = find(node.children ?? []) { return found }
            }
            return nil
        }
        return find(nodes)
    }

    private func serviceSummary(_ service: GATTService) -> String {
        var lines = ["\(service.isPrimary ? "Primary" : "Secondary") Service \(service.uuid.displayName) [\(service.uuid.uuidString)]"]
        for characteristic in service.characteristics {
            lines.append("  \(characteristic.uuid.displayName) [\(characteristic.properties.titles.joined(separator: ", "))]"
                         + (characteristic.value.map { " = \($0.hexString)" } ?? ""))
            for descriptor in characteristic.descriptors {
                lines.append("    \(descriptor.uuid.displayName)" + (descriptor.value.map { " = \($0.displayText)" } ?? ""))
            }
        }
        return lines.joined(separator: "\n")
    }
}

struct GATTNodeRow: View {
    let node: GATTExplorerView.Node

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(node.uuid.shortString)
                        .font(.system(.body, design: .monospaced).weight(.medium))
                    Text(node.title)
                        .lineLimit(1)
                }
                if node.kind == .characteristic {
                    PropertyChips(properties: node.properties, compact: true)
                }
            }
            Spacer(minLength: 0)
            if node.isNotifying {
                Image(systemName: "bell.fill")
                    .foregroundStyle(.purple)
                    .help("Notifications/indications enabled")
            }
            if node.hasError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 1)
    }

    private var symbol: String {
        switch node.kind {
        case .service(let isPrimary): isPrimary ? "square.stack.3d.up" : "square.stack.3d.down.right"
        case .includedService: "arrow.turn.down.right"
        case .characteristic: "circle.hexagongrid"
        case .descriptor: "tag"
        }
    }

    private var color: Color {
        switch node.kind {
        case .service: .indigo
        case .includedService: .secondary
        case .characteristic: .accentColor
        case .descriptor: .gray
        }
    }
}

struct ServiceDetailView: View {
    let device: InspectedDevice
    let service: GATTService

    var body: some View {
        Form {
            Section("Service") {
                InfoRow("Name", service.name)
                InfoRow("UUID", service.uuid.uuidString, monospaced: true)
                InfoRow("Short UUID", service.uuid.shortString, monospaced: true)
                InfoRow("Type", service.isPrimary ? "Primary" : "Secondary")
                InfoRow("Characteristics", "\(service.characteristics.count)")
                InfoRow("Included Services", service.includedServiceIDs.compactMap { device.gatt.service($0)?.uuid.displayName }.joined(separator: ", "))
                InfoRow("Discovery", service.characteristicDiscovery.rawValue)
                if let error = service.lastError { InfoRow("Error", error) }
            }
            if service.uuid.assignedNumber == 0x1812 {
                Section {
                    Label("macOS normally reserves the HID service for the system; apps usually cannot read it.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct DescriptorDetailView: View {
    @Environment(AppModel.self) private var model
    let device: InspectedDevice
    let characteristic: GATTCharacteristic
    let descriptor: GATTDescriptor

    var body: some View {
        Form {
            Section("Descriptor") {
                InfoRow("Name", descriptor.name)
                InfoRow("UUID", descriptor.uuid.uuidString, monospaced: true)
                InfoRow("Characteristic", characteristic.uuid.displayName)
            }
            Section("Value") {
                InfoRow("Raw", descriptor.value?.data.hexString ?? "Not read", monospaced: true)
                InfoRow("As Reported", descriptor.value?.displayText ?? "—")
                if let decoded = model.workspace.decodedValue(of: descriptor) {
                    InfoRow("Decoded", decoded.summary)
                    ForEach(decoded.fields, id: \.self) { field in
                        InfoRow(field.name, field.value)
                    }
                }
                if let error = descriptor.lastError { InfoRow("Error", error) }
                Button("Read Descriptor") { model.workspace.readDescriptor(descriptor.id, on: device.id) }
                    .disabled(device.connectionState != .connected)
            }
            if descriptor.uuid.assignedNumber == 0x2902 {
                Section {
                    Label("The Client Characteristic Configuration descriptor is managed by macOS. Use Subscribe on the characteristic to change it.",
                          systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
