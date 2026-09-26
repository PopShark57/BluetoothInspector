import BluetoothInspectorKit
import SwiftUI

/// Searchable browser of the bundled Bluetooth SIG names, marking which
/// characteristics have a payload decoder.
struct AssignedNumbersView: View {
    @Environment(AppModel.self) private var model
    @State private var kind: AssignedNumbers.Kind?
    @State private var selection: Set<String> = []

    private struct Row: Identifiable {
        let id: String
        let uuid: BluetoothUUID
        let name: String
        let kind: AssignedNumbers.Kind
        let hasDecoder: Bool
    }

    private static let allRows: [Row] = AssignedNumbers.allEntries().map { uuid, entry in
        Row(id: "\(entry.kind.rawValue)-\(uuid.uuidString)", uuid: uuid, name: entry.name, kind: entry.kind,
            hasDecoder: DecoderRegistry.standard.hasDecoder(forCharacteristic: uuid))
    }

    private static let kinds: [AssignedNumbers.Kind] = [.service, .characteristic, .descriptor, .memberService, .serviceClass, .protocol, .vendor]

    var body: some View {
        let matcher = SearchMatcher(model.searchText)
        let rows = Self.allRows.filter { row in
            (kind == nil || row.kind == kind) && matcher.matches(any: [row.uuid.shortString, row.uuid.uuidString, row.name])
        }
        VStack(spacing: 0) {
            HStack {
                Picker("Kind", selection: $kind) {
                    Text("All").tag(AssignedNumbers.Kind?.none)
                    ForEach(Self.kinds, id: \.self) { Text(title(for: $0)).tag(AssignedNumbers.Kind?.some($0)) }
                }
                .fixedSize()
                Spacer()
                Text("\(rows.count) entries").foregroundStyle(.secondary).monospacedDigit()
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Table(rows, selection: $selection) {
                TableColumn("UUID") { row in
                    Text(row.uuid.shortString).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
                .width(min: 60, ideal: 90)
                TableColumn("Name") { row in
                    Text(row.name)
                }
                TableColumn("Kind") { row in
                    Text(title(for: row.kind)).foregroundStyle(.secondary)
                }
                .width(min: 80, ideal: 120)
                TableColumn("Decoder") { row in
                    if row.hasDecoder {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Payloads are decoded")
                    }
                }
                .width(min: 50, ideal: 60)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                let chosen = rows.filter { ids.contains($0.id) }
                Button("Copy UUID") { Pasteboard.copy(chosen.map(\.uuid.uuidString).joined(separator: "\n")) }
                Button("Copy Name") { Pasteboard.copy(chosen.map { "\($0.uuid.shortString) \($0.name)" }.joined(separator: "\n")) }
            }
        }
    }

    private func title(for kind: AssignedNumbers.Kind) -> String {
        switch kind {
        case .service: "GATT Service"
        case .characteristic: "Characteristic"
        case .descriptor: "Descriptor"
        case .serviceClass: "SDP Service Class"
        case .protocol: "Protocol"
        case .memberService: "Member UUID"
        case .unit: "Unit"
        case .vendor: "Vendor"
        }
    }
}
