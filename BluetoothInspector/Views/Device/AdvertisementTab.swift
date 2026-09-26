import BluetoothInspectorKit
import SwiftUI

struct AdvertisementTab: View {
    let device: InspectedDevice
    @State private var selectedField: AdvertisementField.ID?

    var body: some View {
        VSplitView {
            VStack(alignment: .leading, spacing: 0) {
                header("Current Advertisement", detail: "Merged advertising + scan response, as parsed by CoreBluetooth")
                let fields = device.advertisement.fields
                Table(fields, selection: $selectedField) {
                    TableColumn("Field") { field in
                        Text(field.name).foregroundStyle(field.name.hasPrefix(" ") ? .secondary : .primary)
                    }
                    .width(min: 120, ideal: 170)
                    TableColumn("Decoded Value") { field in
                        Text(field.value).textSelection(.enabled)
                    }
                    .width(min: 160, ideal: 280)
                    TableColumn("Raw Hex") { field in
                        Text(field.rawHex)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .contextMenu(forSelectionType: AdvertisementField.ID.self) { ids in
                    if let field = fields.first(where: { ids.contains($0.id) }) {
                        Button("Copy Value") { Pasteboard.copy(field.value) }
                        if !field.rawHex.isEmpty { Button("Copy Hex") { Pasteboard.copy(field.rawHex) } }
                        Button("Copy Row") { Pasteboard.copy("\(field.name.trimmingCharacters(in: .whitespaces))\t\(field.value)\t\(field.rawHex)") }
                    }
                }
                .overlay {
                    if fields.isEmpty {
                        ContentUnavailableView("No Advertisement", systemImage: "megaphone",
                                               description: Text("No advertisement received yet. Start a scan to receive advertisements."))
                    }
                }
            }
            .frame(minHeight: 180)

            PacketHistoryView(device: device)
                .frame(minHeight: 140)
        }
    }

    private func header(_ title: String, detail: String) -> some View {
        HStack {
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text("\(device.advertisementPacketCount) packets · \(device.advertisementChangeCount) changes")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// Individual advertisement callbacks (most recent first), to see how the
/// advertisement and RSSI change over time.
struct PacketHistoryView: View {
    let device: InspectedDevice

    private struct Row: Identifiable {
        let id: Int
        let packet: AdvertisementPacket
    }

    var body: some View {
        _ = device.historyRevision
        let rows = device.packets.enumerated().reversed().prefix(300).map { Row(id: $0.offset, packet: $0.element) }
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recent Packets").font(.headline)
                Text("Each row is one advertising or scan-response callback").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Table(rows) {
                TableColumn("Time") { row in
                    Text(DisplayFormatting.timeWithMilliseconds(row.packet.timestamp)).monospacedDigit()
                }
                .width(min: 90, ideal: 100)
                TableColumn("RSSI") { row in
                    Text(row.packet.rssi.map { "\($0)" } ?? "—").monospacedDigit()
                }
                .width(min: 40, ideal: 50)
                TableColumn("Name") { row in
                    Text(row.packet.advertisement.localName ?? "")
                }
                .width(min: 60, ideal: 110)
                TableColumn("Services") { row in
                    Text(row.packet.advertisement.serviceUUIDs.map(\.shortString).joined(separator: " "))
                        .font(.system(.body, design: .monospaced))
                }
                .width(min: 60, ideal: 110)
                TableColumn("Manufacturer Data") { row in
                    Text(row.packet.advertisement.manufacturerData?.hexString ?? "")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
    }
}
