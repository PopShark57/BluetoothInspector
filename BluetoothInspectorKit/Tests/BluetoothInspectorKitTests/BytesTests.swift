import Foundation
import Testing
@testable import BluetoothInspectorKit

@Suite("Byte formatting")
struct ByteFormatterTests {
    let sample = Data([0x00, 0x48, 0x7F, 0xFF])

    @Test func hexAndCompactHex() {
        #expect(ByteFormatter.hex(sample) == "00 48 7F FF")
        #expect(ByteFormatter.compactHex(sample) == "00487fff")
        #expect(ByteFormatter.hex(Data()) == "")
    }

    @Test func asciiReplacesNonPrintable() {
        #expect(ByteFormatter.ascii(Data("Hi!".utf8) + Data([0x00, 0x0A])) == "Hi!..")
    }

    @Test func strictUTF8() {
        #expect(ByteFormatter.utf8(Data("héllo".utf8)) == "héllo")
        #expect(ByteFormatter.utf8(Data([0xC3, 0x28])) == nil)
    }

    @Test func binary() {
        #expect(ByteFormatter.binary(Data([0x05, 0xA0])) == "00000101 10100000")
    }

    @Test func integersRespectEndiannessAndSign() {
        let data = Data([0x34, 0x12])
        #expect(ByteFormatter.unsignedInteger(data) == 0x1234)
        #expect(ByteFormatter.unsignedInteger(data, endianness: .big) == 0x3412)
        #expect(ByteFormatter.signedInteger(Data([0xFF])) == -1)
        #expect(ByteFormatter.signedInteger(Data([0x00, 0x80])) == -32768)
        #expect(ByteFormatter.signedInteger(Data([0xFF, 0x7F])) == 32767)
        #expect(ByteFormatter.signedInteger(Data(repeating: 0xFF, count: 8)) == -1)
        #expect(ByteFormatter.unsignedInteger(Data(repeating: 0, count: 9)) == nil)
    }

    @Test func formatExplainsMissingInterpretations() {
        #expect(ByteFormatter.format(Data(), as: .hex) == "(empty)")
        #expect(ByteFormatter.format(Data([0xFF, 0xFE]), as: .utf8) == "(not valid UTF-8)")
        #expect(ByteFormatter.format(Data(repeating: 1, count: 10), as: .unsignedInteger).contains("wider than 64 bits"))
        #expect(ByteFormatter.format(Data([0xFE]), as: .signedInteger) == "-2")
    }

    @Test func hexDumpLayout() {
        let dump = ByteFormatter.hexDump(Data(0..<20))
        let lines = dump.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("0000  00 01 02"))
        #expect(lines[1].hasPrefix("0010  10 11 12 13"))
    }
}

@Suite("Hex parsing")
struct HexParserTests {
    @Test(arguments: ["0A1BFF", "0a 1b ff", "0x0A, 0x1B, 0xFF", "0A:1B:FF", "0A-1B-FF", "<0a1bff>", "  0A1b Ff  "])
    func acceptsCommonForms(_ text: String) throws {
        #expect(try HexParser.parse(text) == Data([0x0A, 0x1B, 0xFF]))
    }

    @Test func rejectsOddDigitCount() {
        #expect(throws: HexParseError.oddNumberOfDigits(3)) { try HexParser.parse("ABC") }
    }

    @Test func rejectsInvalidCharacters() {
        #expect(throws: HexParseError.invalidCharacter("G", position: 2)) { try HexParser.parse("0AG1") }
    }

    @Test func rejectsEmpty() {
        #expect(throws: HexParseError.empty) { try HexParser.parse("  , ") }
    }
}

@Suite("Write value encoding")
struct WriteValueEncoderTests {
    @Test func utf8IsVerbatim() throws {
        let result = WriteValueEncoder(format: .utf8).encode(" hi ")
        #expect(try result.get() == Data(" hi ".utf8))
    }

    @Test func hexEncoding() throws {
        #expect(try WriteValueEncoder(format: .hex).encode("01 a0 ff").get() == Data([0x01, 0xA0, 0xFF]))
        #expect(WriteValueEncoder(format: .hex).encode("0").failure == .hex(.oddNumberOfDigits(1)))
    }

    @Test func decimalBytes() throws {
        #expect(try WriteValueEncoder(format: .decimalBytes).encode("1, 160 255").get() == Data([1, 160, 255]))
        #expect(WriteValueEncoder(format: .decimalBytes).encode("256").failure == .decimalByteOutOfRange("256"))
        #expect(WriteValueEncoder(format: .decimalBytes).encode("x").failure == .invalidDecimalByte("x"))
    }

    @Test func unsignedIntegersAreLittleEndianByDefault() throws {
        let encoder = WriteValueEncoder(format: .unsignedInteger, integerWidth: .two)
        #expect(try encoder.encode("1500").get() == Data([0xDC, 0x05]))
        var big = encoder
        big.endianness = .big
        #expect(try big.encode("1500").get() == Data([0x05, 0xDC]))
        #expect(encoder.encode("65536").failure == .integerOutOfRange(value: "65536", width: .two, signed: false))
        #expect(encoder.encode("-1").failure == .integerOutOfRange(value: "-1", width: .two, signed: false))
    }

    @Test func signedIntegerRanges() throws {
        let encoder = WriteValueEncoder(format: .signedInteger, integerWidth: .one)
        #expect(try encoder.encode("-42").get() == Data([0xD6]))
        #expect(try encoder.encode("-128").get() == Data([0x80]))
        #expect(encoder.encode("128").failure == .integerOutOfRange(value: "128", width: .one, signed: true))
        #expect(encoder.encode("1.5").failure == .notAnInteger("1.5"))
        let wide = WriteValueEncoder(format: .signedInteger, integerWidth: .eight)
        #expect(try wide.encode("-1").get() == Data(repeating: 0xFF, count: 8))
    }

    @Test func enforcesMaximumLength() {
        let result = WriteValueEncoder(format: .hex).encode("01 02 03", maximumLength: 2)
        #expect(result.failure == .exceedsMaximumLength(length: 3, maximum: 2))
    }

    @Test func errorsHaveMessages() {
        let errors: [WriteEncodingError] = [.empty, .notAnInteger("x"), .integerOutOfRange(value: "300", width: .one, signed: false)]
        for error in errors { #expect(error.errorDescription?.isEmpty == false) }
        #expect(WriteEncodingError.integerOutOfRange(value: "300", width: .one, signed: false).errorDescription?.contains("0…255") == true)
    }
}

@Suite("IEEE 11073 floats")
struct MedicalFloatTests {
    @Test func sfloatValues() {
        // Mantissa 120, exponent 0.
        #expect(MedicalFloat(sfloat: 0x0078) == .value(120))
        // Mantissa 365, exponent -1 → 36.5
        #expect(MedicalFloat(sfloat: 0xF16D).doubleValue.map { abs($0 - 36.5) < 1e-9 } == true)
        // Negative mantissa: 0xFFF = -1
        #expect(MedicalFloat(sfloat: 0x0FFF) == .value(-1))
    }

    @Test func sfloatSpecialValues() {
        #expect(MedicalFloat(sfloat: 0x07FF) == .notANumber)
        #expect(MedicalFloat(sfloat: 0x0800) == .notAtThisResolution)
        #expect(MedicalFloat(sfloat: 0x07FE) == .positiveInfinity)
        #expect(MedicalFloat(sfloat: 0x0802) == .negativeInfinity)
    }

    @Test func float32Values() {
        // 3670 × 10^-2 = 36.70
        let raw: UInt32 = 0xFE00_0E56
        #expect(MedicalFloat(float32: raw).description == "36.7")
        #expect(MedicalFloat(float32: 0x007F_FFFF) == .notANumber)
    }
}

@Suite("Byte reader")
struct ByteReaderTests {
    @Test func readsLittleEndianAndStopsAtEnd() {
        var reader = ByteReader(Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07]))
        #expect(reader.readUInt8() == 0x01)
        #expect(reader.readUInt16() == 0x0302)
        #expect(reader.readUInt24() == 0x06_0504)
        #expect(reader.readUInt16() == nil)
        #expect(reader.readUInt8() == 0x07)
        #expect(reader.isAtEnd)
    }

    @Test func signed24() {
        var reader = ByteReader(Data([0xFF, 0xFF, 0xFF]))
        #expect(reader.readInt24() == -1)
    }
}

extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
