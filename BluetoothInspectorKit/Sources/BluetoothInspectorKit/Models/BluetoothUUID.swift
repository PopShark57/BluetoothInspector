import Foundation

/// A Bluetooth UUID normalized so 16-bit, 32-bit and 128-bit spellings of the
/// same value compare equal.
///
/// CoreBluetooth reports SIG-assigned UUIDs in their short form (`"180D"`) and
/// vendor UUIDs in full form; IOBluetooth reports raw 2/4/16-byte values. Both
/// are funnelled through this type so lookups and searches behave the same for
/// BLE and Classic.
public struct BluetoothUUID: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    /// Canonical uppercase 128-bit form, e.g. `0000180D-0000-1000-8000-00805F9B34FB`.
    public let uuidString: String

    /// The Bluetooth Base UUID suffix shared by every SIG-assigned short UUID.
    public static let baseSuffix = "-0000-1000-8000-00805F9B34FB"

    public init?(string raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var text = trimmed.uppercased()
        if text.hasPrefix("0X") { text.removeFirst(2) }
        let hexOnly = text.filter { $0 != "-" }
        guard !hexOnly.isEmpty, hexOnly.allSatisfy(\.isHexDigit) else { return nil }
        switch hexOnly.count {
        case 4:
            uuidString = "0000\(hexOnly)\(Self.baseSuffix)"
        case 8:
            uuidString = "\(hexOnly)\(Self.baseSuffix)"
        case 32:
            let chars = Array(hexOnly)
            uuidString = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32]
                .map { String(chars[$0]) }
                .joined(separator: "-")
        default:
            return nil
        }
    }

    public init(uint16 value: UInt16) {
        uuidString = String(format: "0000%04X", value) + Self.baseSuffix
    }

    public init(uint32 value: UInt32) {
        uuidString = String(format: "%08X", value) + Self.baseSuffix
    }

    public init(uuid: UUID) {
        uuidString = uuid.uuidString.uppercased()
    }

    /// Builds a UUID from over-the-air bytes. Bluetooth transmits 16- and
    /// 32-bit UUIDs little-endian; SDP (IOBluetooth) delivers them big-endian,
    /// so the caller states which it has.
    public init?(bytes: [UInt8], bigEndian: Bool) {
        let ordered = bigEndian ? bytes : Array(bytes.reversed())
        let hex = ordered.map { String(format: "%02X", $0) }.joined()
        self.init(string: hex)
    }

    /// True when the UUID lives inside the Bluetooth Base UUID range.
    public var isSIGBased: Bool { uuidString.hasSuffix(Self.baseSuffix) }

    /// The 16-bit alias for SIG-assigned UUIDs (`0x180D` for Heart Rate).
    public var assignedNumber: UInt16? {
        guard isSIGBased, uuidString.hasPrefix("0000") else { return nil }
        let start = uuidString.index(uuidString.startIndex, offsetBy: 4)
        let end = uuidString.index(start, offsetBy: 4)
        return UInt16(uuidString[start..<end], radix: 16)
    }

    /// Shortest conventional spelling: `180D`, `FEAA0001`-style 32-bit, or full.
    public var shortString: String {
        guard isSIGBased else { return uuidString }
        let prefix = String(uuidString.prefix(8))
        return prefix.hasPrefix("0000") ? String(prefix.dropFirst(4)) : prefix
    }

    public var description: String { shortString }

    public static func < (lhs: BluetoothUUID, rhs: BluetoothUUID) -> Bool {
        lhs.uuidString < rhs.uuidString
    }

    // Encode compactly as the short string; decoding accepts any spelling.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let uuid = BluetoothUUID(string: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid Bluetooth UUID \(text)")
        }
        self = uuid
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(shortString)
    }
}

public extension BluetoothUUID {
    /// The Bluetooth SIG name, if this is a known assigned number.
    var sigName: String? { AssignedNumbers.name(for: self) }

    /// `180D Heart Rate` or just the UUID when unknown.
    var displayName: String {
        if let name = sigName { return "\(shortString) \(name)" }
        return shortString
    }
}
