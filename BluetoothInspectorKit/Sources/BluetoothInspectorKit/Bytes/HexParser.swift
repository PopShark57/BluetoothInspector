import Foundation

public enum HexParseError: Error, Equatable, Sendable, LocalizedError {
    case empty
    case invalidCharacter(Character, position: Int)
    case oddNumberOfDigits(Int)

    public var errorDescription: String? {
        switch self {
        case .empty:
            "Enter at least one byte of hex."
        case .invalidCharacter(let character, let position):
            "“\(character)” at position \(position + 1) is not a hex digit."
        case .oddNumberOfDigits(let count):
            "\(count) hex digits is not a whole number of bytes. Add a leading 0 to the last byte."
        }
    }
}

/// Parses user-entered hex in the forms developers commonly paste:
/// `0A1BFF`, `0a 1b ff`, `0x0A, 0x1B`, `0A:1B:FF`, `0A-1B-FF`, `<0a1bff>`.
public enum HexParser {
    public static func parse(_ text: String) throws(HexParseError) -> Data {
        var digits: [UInt8] = []
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            // Accept a `0x` prefix on each byte group.
            if character == "0", index + 1 < characters.count,
               characters[index + 1] == "x" || characters[index + 1] == "X" {
                index += 2
                continue
            }
            if character.isWhitespace || ",:;-_<>[]{}".contains(character) {
                index += 1
                continue
            }
            guard let nibble = character.hexDigitValue else {
                throw .invalidCharacter(character, position: index)
            }
            digits.append(UInt8(nibble))
            index += 1
        }
        guard !digits.isEmpty else { throw .empty }
        guard digits.count.isMultiple(of: 2) else { throw .oddNumberOfDigits(digits.count) }
        var bytes = [UInt8]()
        bytes.reserveCapacity(digits.count / 2)
        for pair in stride(from: 0, to: digits.count, by: 2) {
            bytes.append(digits[pair] << 4 | digits[pair + 1])
        }
        return Data(bytes)
    }
}
