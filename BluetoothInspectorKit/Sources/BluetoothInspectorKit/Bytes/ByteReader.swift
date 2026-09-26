import Foundation

/// A bounds-checked little-endian cursor over a Bluetooth payload.
///
/// Bluetooth SIG characteristics are little-endian unless a specification says
/// otherwise. Every read returns `nil` instead of trapping when the payload is
/// shorter than the specification requires, because real devices frequently
/// send truncated or malformed values.
public struct ByteReader: Sendable {
    public let bytes: [UInt8]
    public private(set) var offset: Int = 0

    public init(_ data: Data) {
        self.bytes = [UInt8](data)
    }

    public init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    public var remaining: Int { bytes.count - offset }
    public var isAtEnd: Bool { offset >= bytes.count }

    public mutating func readUInt8() -> UInt8? {
        guard remaining >= 1 else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    public mutating func readInt8() -> Int8? {
        readUInt8().map { Int8(bitPattern: $0) }
    }

    public mutating func readUInt16() -> UInt16? {
        readUnsigned(byteCount: 2).map { UInt16(truncatingIfNeeded: $0) }
    }

    public mutating func readInt16() -> Int16? {
        readUInt16().map { Int16(bitPattern: $0) }
    }

    public mutating func readUInt24() -> UInt32? {
        readUnsigned(byteCount: 3).map { UInt32(truncatingIfNeeded: $0) }
    }

    public mutating func readUInt32() -> UInt32? {
        readUnsigned(byteCount: 4).map { UInt32(truncatingIfNeeded: $0) }
    }

    public mutating func readInt32() -> Int32? {
        readUInt32().map { Int32(bitPattern: $0) }
    }

    public mutating func readUInt48() -> UInt64? {
        readUnsigned(byteCount: 6)
    }

    public mutating func readUInt64() -> UInt64? {
        readUnsigned(byteCount: 8)
    }

    /// IEEE 11073-20601 16-bit SFLOAT (used by Blood Pressure, PLX, Glucose…).
    public mutating func readSFloat() -> MedicalFloat? {
        readUInt16().map(MedicalFloat.init(sfloat:))
    }

    /// IEEE 11073-20601 32-bit FLOAT (used by Health Thermometer).
    public mutating func readFloat32() -> MedicalFloat? {
        readUInt32().map(MedicalFloat.init(float32:))
    }

    public mutating func readBytes(_ count: Int) -> [UInt8]? {
        guard count >= 0, remaining >= count else { return nil }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }

    public mutating func readRemaining() -> [UInt8] {
        readBytes(remaining) ?? []
    }

    public mutating func skip(_ count: Int) -> Bool {
        guard count >= 0, remaining >= count else { return false }
        offset += count
        return true
    }

    private mutating func readUnsigned(byteCount: Int) -> UInt64? {
        guard byteCount <= 8, remaining >= byteCount else { return nil }
        var value: UInt64 = 0
        for index in 0..<byteCount {
            value |= UInt64(bytes[offset + index]) << (8 * UInt64(index))
        }
        offset += byteCount
        return value
    }
}

/// An IEEE 11073-20601 medical float (SFLOAT or FLOAT), including the reserved
/// special values the standard defines.
public enum MedicalFloat: Sendable, Equatable, CustomStringConvertible {
    case value(Double)
    case notANumber
    case notAtThisResolution
    case positiveInfinity
    case negativeInfinity
    case reserved

    /// Decodes a 16-bit SFLOAT: 4-bit signed exponent, 12-bit signed mantissa.
    public init(sfloat raw: UInt16) {
        switch raw {
        case 0x07FF: self = .notANumber
        case 0x0800: self = .notAtThisResolution
        case 0x07FE: self = .positiveInfinity
        case 0x0802: self = .negativeInfinity
        case 0x0801: self = .reserved
        default:
            var mantissa = Int32(raw & 0x0FFF)
            if mantissa >= 0x0800 { mantissa -= 0x1000 }
            var exponent = Int32(raw >> 12)
            if exponent >= 0x8 { exponent -= 0x10 }
            self = .value(Double(mantissa) * pow(10.0, Double(exponent)))
        }
    }

    /// Decodes a 32-bit FLOAT: 8-bit signed exponent, 24-bit signed mantissa.
    public init(float32 raw: UInt32) {
        let mantissaBits = raw & 0x00FF_FFFF
        switch mantissaBits {
        case 0x007F_FFFF: self = .notANumber
        case 0x0080_0000: self = .notAtThisResolution
        case 0x007F_FFFE: self = .positiveInfinity
        case 0x0080_0002: self = .negativeInfinity
        case 0x0080_0001: self = .reserved
        default:
            var mantissa = Int64(mantissaBits)
            if mantissa >= 0x0080_0000 { mantissa -= 0x0100_0000 }
            let exponent = Int64(Int8(bitPattern: UInt8(raw >> 24)))
            self = .value(Double(mantissa) * pow(10.0, Double(exponent)))
        }
    }

    public var doubleValue: Double? {
        if case .value(let value) = self { return value }
        return nil
    }

    public var description: String {
        switch self {
        case .value(let value): return MedicalFloat.format(value)
        case .notANumber: return "NaN"
        case .notAtThisResolution: return "NRes"
        case .positiveInfinity: return "+INF"
        case .negativeInfinity: return "-INF"
        case .reserved: return "Reserved"
        }
    }

    static func format(_ value: Double) -> String {
        if value.rounded() == value, abs(value) < 1e15 {
            return String(Int64(value))
        }
        // Trim binary floating point noise (e.g. 36.700000000000003).
        var text = String(format: "%.6f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
