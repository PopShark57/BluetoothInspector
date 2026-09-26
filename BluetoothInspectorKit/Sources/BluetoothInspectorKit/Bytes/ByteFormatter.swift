import Foundation

/// The representations the Raw Data views offer for a byte payload.
public enum ByteDisplayFormat: String, CaseIterable, Identifiable, Codable, Sendable {
    case hex
    case ascii
    case utf8
    case unsignedInteger
    case signedInteger
    case binary

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .hex: "Hex"
        case .ascii: "ASCII"
        case .utf8: "UTF-8"
        case .unsignedInteger: "Unsigned"
        case .signedInteger: "Signed"
        case .binary: "Binary"
        }
    }
}

public enum Endianness: String, CaseIterable, Identifiable, Codable, Sendable {
    case little
    case big

    public var id: String { rawValue }
    public var title: String { self == .little ? "Little-endian" : "Big-endian" }
}

/// Formats raw bytes for display, copying and export.
public enum ByteFormatter {
    /// `0A 1B FF` style hex. An empty payload renders as an empty string.
    public static func hex(_ data: Data, separator: String = " ", uppercase: Bool = true) -> String {
        let format = uppercase ? "%02X" : "%02x"
        return data.map { String(format: format, $0) }.joined(separator: separator)
    }

    /// Hex without separators, e.g. for JSON export (`0a1bff`).
    public static func compactHex(_ data: Data) -> String {
        hex(data, separator: "", uppercase: false)
    }

    /// Printable ASCII with every other byte shown as `.` (like `xxd`).
    public static func ascii(_ data: Data) -> String {
        String(data.map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "." })
    }

    /// Strict UTF-8 decoding. Returns `nil` if the payload is not valid UTF-8,
    /// so callers can say "not valid UTF-8" instead of showing replacement
    /// characters that hide the real bytes.
    public static func utf8(_ data: Data) -> String? {
        String(bytes: data, encoding: .utf8)
    }

    public static func binary(_ data: Data, separator: String = " ") -> String {
        data.map { byte in
            let bits = String(byte, radix: 2)
            return String(repeating: "0", count: 8 - bits.count) + bits
        }.joined(separator: separator)
    }

    /// Interprets the whole payload as one unsigned integer. Only payloads of
    /// 1–8 bytes have an integer interpretation.
    public static func unsignedInteger(_ data: Data, endianness: Endianness = .little) -> UInt64? {
        guard (1...8).contains(data.count) else { return nil }
        let ordered: [UInt8] = endianness == .little ? Array(data) : Array(data.reversed())
        var value: UInt64 = 0
        for (index, byte) in ordered.enumerated() {
            value |= UInt64(byte) << (8 * UInt64(index))
        }
        return value
    }

    /// Two's complement interpretation sized to the payload length.
    public static func signedInteger(_ data: Data, endianness: Endianness = .little) -> Int64? {
        guard let unsigned = unsignedInteger(data, endianness: endianness) else { return nil }
        let bitWidth = UInt64(data.count * 8)
        if bitWidth == 64 { return Int64(bitPattern: unsigned) }
        let signBit: UInt64 = 1 << (bitWidth - 1)
        if unsigned & signBit != 0 {
            return Int64(bitPattern: unsigned | ~((1 << bitWidth) - 1))
        }
        return Int64(unsigned)
    }

    /// Renders a payload in the requested format with a human explanation
    /// when that interpretation does not exist.
    public static func format(_ data: Data, as format: ByteDisplayFormat, endianness: Endianness = .little) -> String {
        if data.isEmpty { return "(empty)" }
        switch format {
        case .hex:
            return hex(data)
        case .ascii:
            return ascii(data)
        case .utf8:
            return utf8(data) ?? "(not valid UTF-8)"
        case .binary:
            return binary(data)
        case .unsignedInteger:
            if let value = unsignedInteger(data, endianness: endianness) { return String(value) }
            return perByte(data) { String($0) } + "  (per byte; \(data.count) bytes is wider than 64 bits)"
        case .signedInteger:
            if let value = signedInteger(data, endianness: endianness) { return String(value) }
            return perByte(data) { String(Int8(bitPattern: $0)) } + "  (per byte; \(data.count) bytes is wider than 64 bits)"
        }
    }

    private static func perByte(_ data: Data, _ transform: (UInt8) -> String) -> String {
        data.map(transform).joined(separator: " ")
    }

    /// A classic hex dump with offsets and an ASCII gutter, 16 bytes per row.
    public static func hexDump(_ data: Data) -> String {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return "(empty)" }
        var lines: [String] = []
        var index = 0
        while index < bytes.count {
            let row = bytes[index..<min(index + 16, bytes.count)]
            let hexPart = row.map { String(format: "%02X", $0) }.joined(separator: " ")
            let padded = hexPart.padding(toLength: 16 * 3 - 1, withPad: " ", startingAt: 0)
            lines.append(String(format: "%04X  ", index) + padded + "  " + ascii(Data(row)))
            index += 16
        }
        return lines.joined(separator: "\n")
    }
}

public extension Data {
    /// Uppercase, space separated hex (`0A 1B`).
    var hexString: String { ByteFormatter.hex(self) }
}
