import BluetoothInspectorKit
import SwiftUI

/// SDP service records of a Classic device, with a browsable attribute tree.
struct ClassicServicesView: View {
    @Environment(AppModel.self) private var model
    let device: InspectedDevice

    var body: some View {
        let records = device.classic?.serviceRecords ?? []
        VStack(spacing: 0) {
            HStack {
                if let cod = device.classic?.classOfDevice {
                    Label("\(cod.majorName) – \(cod.minorName)", systemImage: cod.symbolName)
                    Text(cod.hexString).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer()
                if device.isSDPQueryRunning {
                    ProgressView().controlSize(.small)
                    Text("Querying…").foregroundStyle(.secondary)
                }
                Button {
                    model.workspace.performSDPQuery(device.id)
                } label: {
                    Label("Query SDP", systemImage: "arrow.clockwise")
                }
                .disabled(device.isSDPQueryRunning)
                .help("Performs a Service Discovery Protocol query. macOS may open a short baseband connection to the device.")
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()

            if records.isEmpty {
                ContentUnavailableView {
                    Label("No Service Records", systemImage: "list.bullet.rectangle")
                } description: {
                    Text("Run an SDP query to list the Classic profiles this device offers. The device must be in range; unpaired devices may need to be discoverable.")
                } actions: {
                    Button("Query SDP") { model.workspace.performSDPQuery(device.id) }
                        .disabled(device.isSDPQueryRunning)
                }
            } else {
                List {
                    ForEach(records) { record in
                        SDPRecordView(record: record)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
    }
}

struct SDPRecordView: View {
    let record: SDPServiceRecord
    @State private var expanded = false

    /// Identifiable tree for OutlineGroup.
    struct Node: Identifiable {
        let id: String
        let label: String
        let value: String
        let children: [Node]?
    }

    private var nodes: [Node] {
        record.attributes.map { attribute in
            let name = attribute.name(inPnPRecord: record.isPnPInformation)
            return node(attribute.value, id: "\(attribute.id)", label: String(format: "0x%04X %@", attribute.id, name))
        }
    }

    private func node(_ element: SDPDataElement, id: String, label: String) -> Node {
        let children = element.children?.enumerated().map { index, child in
            node(child, id: "\(id).\(index)", label: "[\(index)] \(child.typeName)")
        }
        return Node(id: id, label: label, value: element.displayValue, children: children)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            OutlineGroup(nodes, children: \.children) { node in
                HStack {
                    Text(node.label)
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                    Text(node.value)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                }
                .contextMenu {
                    Button("Copy Value") { Pasteboard.copy(node.value) }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title).font(.headline)
                if !record.summary.isEmpty {
                    Text(record.summary).font(.caption).foregroundStyle(.secondary)
                }
                Text(record.serviceClassIDs.map(\.displayName).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contextMenu {
                Button("Copy Service Information") {
                    let text = ([record.title, record.summary] + record.attributes.map {
                        String(format: "0x%04X ", $0.id) + $0.name(inPnPRecord: record.isPnPInformation) + "\n" + $0.value.render(indent: 1)
                    }).joined(separator: "\n")
                    Pasteboard.copy(text)
                }
            }
        }
    }
}
