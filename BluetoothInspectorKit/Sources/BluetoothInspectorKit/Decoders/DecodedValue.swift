import Foundation

/// A human-readable interpretation of a payload.
public struct DecodedValue: Hashable, Codable, Sendable {
    public struct Field: Hashable, Codable, Sendable {
        public let name: String
        public let value: String

        public init(_ name: String, _ value: String) {
            self.name = name
            self.value = value
        }
    }

    /// One-line summary for tables and the console, e.g. `Heart Rate: 72 BPM`.
    public let summary: String
    /// Every decoded field in specification order.
    public let fields: [Field]
    /// Name of the decoder that produced this value (for provenance in exports).
    public let decoder: String

    public init(summary: String, fields: [Field] = [], decoder: String) {
        self.summary = summary
        self.fields = fields
        self.decoder = decoder
    }
}

/// Decoded manufacturer-specific advertisement data (AD type 0xFF).
public struct ManufacturerData: Hashable, Sendable {
    public let companyID: UInt16
    public let payload: Data

    /// The first two bytes are the little-endian Bluetooth SIG company identifier.
    public init?(data: Data) {
        guard data.count >= 2 else { return nil }
        let bytes = [UInt8](data)
        companyID = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
        payload = Data(bytes.dropFirst(2))
    }

    public var companyName: String? { AssignedNumbers.companyName(companyID) }

    public var companyDescription: String {
        let id = String(format: "0x%04X", companyID)
        return companyName.map { "\($0) (\(id))" } ?? "Unknown company \(id)"
    }

    public var summary: String {
        if let vendor = vendorDecoded { return "\(companyDescription) – \(vendor.summary)" }
        return "\(companyDescription), \(payload.count) byte payload"
    }

    public var fields: [DecodedValue.Field] {
        var result = [DecodedValue.Field("Company", companyDescription), .init("Payload", payload.hexString)]
        result += vendorDecoded?.fields ?? []
        return result
    }

    /// Vendor formats that are publicly documented.
    public var vendorDecoded: DecodedValue? {
        if companyID == 0x004C { return AppleManufacturerDecoder.decode(payload) }
        return nil
    }
}

/// Apple (0x004C) manufacturer data is a sequence of type-length-value items.
/// Only iBeacon is publicly documented; other types are identified by their
/// commonly known type byte but their contents are not interpreted.
enum AppleManufacturerDecoder {
    static let knownTypes: [UInt8: String] = [
        0x02: "iBeacon",
        0x05: "AirDrop",
        0x07: "Proximity Pairing",
        0x09: "AirPlay Target",
        0x0C: "Handoff",
        0x0F: "Nearby Action",
        0x10: "Nearby Info",
        0x12: "Find My",
    ]

    static func decode(_ payload: Data) -> DecodedValue? {
        var reader = ByteReader(payload)
        var fields: [DecodedValue.Field] = []
        var names: [String] = []
        while let type = reader.readUInt8(), let length = reader.readUInt8() {
            guard let body = reader.readBytes(Int(length)) else {
                fields.append(.init("Truncated item", String(format: "type 0x%02X claims %d bytes", type, length)))
                break
            }
            let name = knownTypes[type] ?? String(format: "Type 0x%02X", type)
            names.append(name)
            if type == 0x02, length == 0x15, let beacon = iBeacon(body) {
                fields += beacon
            } else {
                fields.append(.init(name, Data(body).hexString))
            }
        }
        guard !names.isEmpty else { return nil }
        return DecodedValue(summary: names.joined(separator: ", "), fields: fields, decoder: "Apple Continuity")
    }

    /// iBeacon: 16-byte proximity UUID, big-endian major and minor, signed measured power.
    static func iBeacon(_ body: [UInt8]) -> [DecodedValue.Field]? {
        guard body.count == 21 else { return nil }
        let uuidBytes = Array(body[0..<16])
        let hex = uuidBytes.map { String(format: "%02X", $0) }.joined()
        let uuid = BluetoothUUID(string: hex)?.uuidString ?? hex
        let major = UInt16(body[16]) << 8 | UInt16(body[17])
        let minor = UInt16(body[18]) << 8 | UInt16(body[19])
        let power = Int8(bitPattern: body[20])
        return [
            .init("iBeacon UUID", uuid),
            .init("Major", "\(major)"),
            .init("Minor", "\(minor)"),
            .init("Measured Power", "\(power) dBm @ 1 m"),
        ]
    }
}

/// Decoders for service data (AD type 0x16 and friends) keyed by service UUID.
public enum ServiceDataDecoder {
    public static func decode(uuid: BluetoothUUID, data: Data) -> DecodedValue? {
        switch uuid.assignedNumber {
        case 0xFEAA: return eddystone(data)
        case 0x180F:
            guard data.count == 1 else { return nil }
            return DecodedValue(summary: "Battery \(data[data.startIndex])%", decoder: "Battery Service Data")
        default:
            // Many sensors advertise a characteristic value as service data of
            // its parent service; fall back to characteristic decoders keyed by
            // the same UUID when one exists.
            return DecoderRegistry.standard.decode(characteristic: uuid, data: data)
        }
    }

    /// Google Eddystone frames (UID, URL, TLM, EID).
    static func eddystone(_ data: Data) -> DecodedValue? {
        var reader = ByteReader(data)
        guard let frame = reader.readUInt8() else { return nil }
        switch frame {
        case 0x00:
            guard let power = reader.readInt8(), let namespace = reader.readBytes(10), let instance = reader.readBytes(6) else { return nil }
            return DecodedValue(summary: "Eddystone-UID", fields: [
                .init("TX Power @ 0 m", "\(power) dBm"),
                .init("Namespace", Data(namespace).hexString),
                .init("Instance", Data(instance).hexString),
            ], decoder: "Eddystone")
        case 0x10:
            guard let power = reader.readInt8(), let scheme = reader.readUInt8() else { return nil }
            let schemes = ["http://www.", "https://www.", "http://", "https://"]
            let expansions = [".com/", ".org/", ".edu/", ".net/", ".info/", ".biz/", ".gov/",
                              ".com", ".org", ".edu", ".net", ".info", ".biz", ".gov"]
            var url = schemes[safe: Int(scheme)] ?? ""
            for byte in reader.readRemaining() {
                if let expansion = expansions[safe: Int(byte)] {
                    url += expansion
                } else if (0x21...0x7E).contains(byte) {
                    url.append(Character(UnicodeScalar(byte)))
                }
            }
            return DecodedValue(summary: "Eddystone-URL \(url)", fields: [
                .init("TX Power @ 0 m", "\(power) dBm"), .init("URL", url),
            ], decoder: "Eddystone")
        case 0x20:
            guard let version = reader.readUInt8() else { return nil }
            if version == 0x00, let battery = reader.readUInt16BE(), let temp = reader.readInt16BE(),
               let count = reader.readUInt32BE(), let uptime = reader.readUInt32BE() {
                let celsius = Double(temp) / 256.0
                return DecodedValue(summary: "Eddystone-TLM", fields: [
                    .init("Battery", battery == 0 ? "Not supported" : "\(battery) mV"),
                    .init("Temperature", temp == Int16(bitPattern: 0x8000) ? "Not supported" : String(format: "%.2f °C", celsius)),
                    .init("Advertising PDU Count", "\(count)"),
                    .init("Time Since Power-on", String(format: "%.1f s", Double(uptime) / 10)),
                ], decoder: "Eddystone")
            }
            return DecodedValue(summary: "Eddystone-TLM (encrypted, version \(version))", decoder: "Eddystone")
        case 0x30:
            return DecodedValue(summary: "Eddystone-EID", fields: [.init("Ephemeral ID", Data(reader.readRemaining().dropFirst()).hexString)], decoder: "Eddystone")
        default:
            return nil
        }
    }
}

extension ByteReader {
    // Eddystone is one of the few Bluetooth formats that uses big-endian fields.
    mutating func readUInt16BE() -> UInt16? {
        guard let bytes = readBytes(2) else { return nil }
        return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    }

    mutating func readInt16BE() -> Int16? {
        readUInt16BE().map { Int16(bitPattern: $0) }
    }

    mutating func readUInt32BE() -> UInt32? {
        guard let bytes = readBytes(4) else { return nil }
        return bytes.reduce(0) { $0 << 8 | UInt32($1) }
    }
}
