import Foundation

/// How the user typed the value they want to write to a characteristic.
public enum WriteInputFormat: String, CaseIterable, Identifiable, Codable, Sendable {
    case utf8
    case hex
    case decimalBytes
    case signedInteger
    case unsignedInteger

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .utf8: "UTF-8 Text"
        case .hex: "Hex"
        case .decimalBytes: "Decimal Bytes"
        case .signedInteger: "Signed Integer"
        case .unsignedInteger: "Unsigned Integer"
        }
    }

    public var placeholder: String {
        switch self {
        case .utf8: "Hello"
        case .hex: "01 A0 FF"
        case .decimalBytes: "1, 160, 255"
        case .signedInteger: "-42"
        case .unsignedInteger: "1500"
        }
    }

    public var usesIntegerWidth: Bool {
        self == .signedInteger || self == .unsignedInteger
    }
}

/// Width of an integer write, in bytes.
public enum IntegerWidth: Int, CaseIterable, Identifiable, Codable, Sendable {
    case one = 1
    case two = 2
    case four = 4
    case eight = 8

    public var id: Int { rawValue }
    public var title: String { "\(rawValue * 8)-bit" }
}

public enum WriteEncodingError: Error, Equatable, Sendable, LocalizedError {
    case empty
    case hex(HexParseError)
    case invalidDecimalByte(String)
    case decimalByteOutOfRange(String)
    case notAnInteger(String)
    case integerOutOfRange(value: String, width: IntegerWidth, signed: Bool)
    case exceedsMaximumLength(length: Int, maximum: Int)

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "Enter a value to write."
        case .hex(let error):
            return error.errorDescription
        case .invalidDecimalByte(let token):
            return "“\(token)” is not a decimal byte."
        case .decimalByteOutOfRange(let token):
            return "\(token) is outside the byte range 0–255."
        case .notAnInteger(let text):
            return "“\(text)” is not a whole number."
        case .integerOutOfRange(let value, let width, let signed):
            let range = WriteValueEncoder.range(width: width, signed: signed)
            return "\(value) does not fit in a \(signed ? "signed" : "unsigned") \(width.title) integer (\(range))."
        case .exceedsMaximumLength(let length, let maximum):
            return "\(length) bytes exceeds the \(maximum)-byte maximum CoreBluetooth reports for this write type."
        }
    }
}

/// Converts editor text into the exact bytes that will be sent to a device.
///
/// Encoding is deliberately separate from sending: the UI previews the bytes
/// produced here, and nothing is written until the user explicitly confirms.
public struct WriteValueEncoder: Sendable, Equatable {
    public var format: WriteInputFormat
    public var integerWidth: IntegerWidth
    public var endianness: Endianness

    public init(format: WriteInputFormat, integerWidth: IntegerWidth = .one, endianness: Endianness = .little) {
        self.format = format
        self.integerWidth = integerWidth
        self.endianness = endianness
    }

    public func encode(_ text: String, maximumLength: Int? = nil) -> Result<Data, WriteEncodingError> {
        let result: Result<Data, WriteEncodingError>
        switch format {
        case .utf8:
            // Text is sent verbatim (no trimming, no terminator) because many
            // devices treat spaces and length as significant.
            result = text.isEmpty ? .failure(.empty) : .success(Data(text.utf8))
        case .hex:
            do {
                result = .success(try HexParser.parse(text))
            } catch {
                result = .failure(error == .empty ? .empty : .hex(error))
            }
        case .decimalBytes:
            result = Self.decimalBytes(text)
        case .signedInteger:
            result = integer(text, signed: true)
        case .unsignedInteger:
            result = integer(text, signed: false)
        }
        if case .success(let data) = result, let maximumLength, data.count > maximumLength {
            return .failure(.exceedsMaximumLength(length: data.count, maximum: maximumLength))
        }
        return result
    }

    private static func decimalBytes(_ text: String) -> Result<Data, WriteEncodingError> {
        let tokens = text
            .split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" })
            .map(String.init)
        guard !tokens.isEmpty else { return .failure(.empty) }
        var bytes: [UInt8] = []
        for token in tokens {
            guard let value = Int(token) else { return .failure(.invalidDecimalByte(token)) }
            guard (0...255).contains(value) else { return .failure(.decimalByteOutOfRange(token)) }
            bytes.append(UInt8(value))
        }
        return .success(Data(bytes))
    }

    private func integer(_ text: String, signed: Bool) -> Result<Data, WriteEncodingError> {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        let bitWidth = integerWidth.rawValue * 8
        let pattern: UInt64
        if signed {
            guard let value = Int64(trimmed) else {
                return .failure(Self.isNumeric(trimmed)
                    ? .integerOutOfRange(value: trimmed, width: integerWidth, signed: true)
                    : .notAnInteger(trimmed))
            }
            if bitWidth < 64 {
                let limit = Int64(1) << (bitWidth - 1)
                guard value >= -limit, value < limit else {
                    return .failure(.integerOutOfRange(value: trimmed, width: integerWidth, signed: true))
                }
            }
            pattern = UInt64(bitPattern: value)
        } else {
            guard let value = UInt64(trimmed) else {
                return .failure(Self.isNumeric(trimmed)
                    ? .integerOutOfRange(value: trimmed, width: integerWidth, signed: false)
                    : .notAnInteger(trimmed))
            }
            if bitWidth < 64 {
                guard value < (UInt64(1) << bitWidth) else {
                    return .failure(.integerOutOfRange(value: trimmed, width: integerWidth, signed: false))
                }
            }
            pattern = value
        }
        var bytes = (0..<integerWidth.rawValue).map { UInt8(truncatingIfNeeded: pattern >> (8 * UInt64($0))) }
        if endianness == .big { bytes.reverse() }
        return .success(Data(bytes))
    }

    private static func isNumeric(_ text: String) -> Bool {
        var body = Substring(text)
        if body.first == "-" || body.first == "+" { body = body.dropFirst() }
        return !body.isEmpty && body.allSatisfy(\.isNumber)
    }

    static func range(width: IntegerWidth, signed: Bool) -> String {
        let bits = width.rawValue * 8
        if signed {
            if bits == 64 { return "\(Int64.min)…\(Int64.max)" }
            let limit = Int64(1) << (bits - 1)
            return "\(-limit)…\(limit - 1)"
        }
        if bits == 64 { return "0…\(UInt64.max)" }
        return "0…\((UInt64(1) << bits) - 1)"
    }
}
