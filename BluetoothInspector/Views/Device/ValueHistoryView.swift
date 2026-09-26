import BluetoothInspectorKit
import SwiftUI

/// Real-time table of notifications/indications, read responses and writes.
struct ValueHistoryView: View {
    @Environment(AppModel.self) private var model
    let device: InspectedDevice
    var characteristicID: GATTNodeID?
    @State private var kindFilter: KindFilter = .all
    @State private var selection: Set<ValueRecord.ID> = []

    enum KindFilter: String, CaseIterable, Identifiable {
        case all, notifications, reads, writes
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "All"
            case .notifications: "Notifications"
            case .reads: "Reads"
            case .writes: "Writes"
            }
        }

        func matches(_ kind: ValueRecord.Kind) -> Bool {
            switch self {
            case .all: true
            case .notifications: kind == .notification
            case .reads: kind == .read
            case .writes: kind == .write
            }
        }
    }

    var body: some View {
        let _ = device.historyRevision
        let records = device.valueRecords
            .filter { (characteristicID == nil || $0.characteristicID == characteristicID) && kindFilter.matches($0.kind) }
            .reversed()
            .map { $0 }
        VStack(spacing: 0) {
            HStack {
                Picker("Show", selection: $kindFilter) {
                    ForEach(KindFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Spacer()
                Text("\(records.count) values")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button {
                    let csv = CSVExporter.values(records.reversed())
                    model.present(PendingExport(document: ExportDocument(text: csv, format: .csv),
                                                filename: ExportDocument.filename("\(device.displayName)-values", format: .csv)))
                } label: {
                    Label("Export CSV", systemImage: "square.and.arrow.up")
                }
                .disabled(records.isEmpty)
                Button {
                    device.clearValueHistory()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(records.isEmpty)
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Table(records, selection: $selection) {
                TableColumn("Time") { record in
                    Text(DisplayFormatting.timeWithMilliseconds(record.timestamp)).monospacedDigit()
                }
                .width(min: 90, ideal: 100)
                TableColumn("Kind") { record in
                    Label(record.kind.title, systemImage: record.kind.symbolName)
                        .foregroundStyle(record.kind.color)
                        .labelStyle(.titleAndIcon)
                }
                .width(min: 90, ideal: 120)
                TableColumn("Characteristic") { record in
                    Text(record.characteristicUUID.displayName).lineLimit(1)
                }
                .width(min: 120, ideal: 200)
                TableColumn("Decoded") { record in
                    Text(record.decodedSummary ?? "—")
                        .foregroundStyle(record.decodedSummary == nil ? .secondary : .primary)
                        .lineLimit(1)
                }
                .width(min: 100, ideal: 180)
                TableColumn("Hex") { record in
                    Text(record.data.isEmpty ? "(empty)" : record.data.hexString)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                }
                .width(min: 100, ideal: 200)
                TableColumn("Bytes") { record in
                    Text("\(record.data.count)").monospacedDigit()
                }
                .width(min: 36, ideal: 44)
            }
            .contextMenu(forSelectionType: ValueRecord.ID.self) { ids in
                let chosen = records.filter { ids.contains($0.id) }
                Button("Copy Hex") { Pasteboard.copy(chosen.map(\.data.hexString).joined(separator: "\n")) }
                Button("Copy Decoded") { Pasteboard.copy(chosen.compactMap(\.decodedSummary).joined(separator: "\n")) }
                Button("Copy Rows") {
                    Pasteboard.copy(chosen.map {
                        "\(DisplayFormatting.timeWithMilliseconds($0.timestamp))\t\($0.kind.rawValue)\t\($0.characteristicUUID.shortString)\t\($0.decodedSummary ?? "")\t\($0.data.hexString)"
                    }.joined(separator: "\n"))
                }
            }
            .overlay {
                if records.isEmpty {
                    ContentUnavailableView("No Values Yet", systemImage: "bell",
                                           description: Text("Subscribe to a Notify/Indicate characteristic or read a value in the GATT tab. Values appear here in real time."))
                }
            }
        }
    }
}
