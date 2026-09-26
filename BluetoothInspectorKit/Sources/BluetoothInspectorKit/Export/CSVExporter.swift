import Foundation

/// RFC 4180 CSV for tabular data (events, device lists, value histories).
public enum CSVExporter {
    public static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public static func document(header: [String], rows: [[String]]) -> String {
        ([header] + rows).map { $0.map(escape).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    static func timestamp(_ date: Date?) -> String {
        date.map { Date.ISO8601FormatStyle(includingFractionalSeconds: true).format($0) } ?? ""
    }

    public static func events(_ events: [ActivityEvent]) -> String {
        document(
            header: ["sequence", "timestamp", "category", "device_id", "device_name", "uuid", "uuid_name", "message", "hex"],
            rows: events.map {
                [String($0.id), timestamp($0.timestamp), $0.category.rawValue, $0.deviceID?.rawValue ?? "", $0.deviceName ?? "",
                 $0.uuid?.shortString ?? "", $0.uuid?.sigName ?? "", $0.message, $0.data.map(ByteFormatter.compactHex) ?? ""]
            }
        )
    }

    public static func devices(_ items: [DeviceListItem]) -> String {
        document(
            header: ["id", "identifier", "name", "transport", "rssi_dbm", "connection", "manufacturer", "last_seen",
                     "connectable", "paired", "favorite", "dual_mode_hint", "services"],
            rows: items.map {
                [$0.id.rawValue, $0.identifierString, $0.name ?? "", $0.transport.rawValue, $0.rssi.map(String.init) ?? "",
                 $0.connectionState.rawValue, $0.manufacturer ?? "", timestamp($0.lastSeen),
                 $0.isConnectable.map { $0 ? "yes" : "no" } ?? "", $0.isPaired.map { $0 ? "yes" : "no" } ?? "",
                 $0.isFavorite ? "yes" : "no", $0.dualModeHint.rawValue,
                 $0.serviceUUIDs.map(\.shortString).joined(separator: " ")]
            }
        )
    }

    public static func values(_ records: [ValueRecord]) -> String {
        document(
            header: ["timestamp", "kind", "characteristic_uuid", "characteristic_name", "byte_count", "hex", "decoded"],
            rows: records.map {
                [timestamp($0.timestamp), $0.kind.rawValue, $0.characteristicUUID.shortString, $0.characteristicUUID.sigName ?? "",
                 String($0.data.count), ByteFormatter.compactHex($0.data), $0.decodedSummary ?? ""]
            }
        )
    }

    public static func rssi(_ samples: [RSSISample]) -> String {
        document(header: ["timestamp", "rssi_dbm"], rows: samples.map { [timestamp($0.timestamp), String($0.value)] })
    }
}
