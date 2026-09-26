import Foundation

/// Case- and diacritic-insensitive matching where every whitespace-separated
/// token must appear somewhere in the candidate text.
///
/// Hex-looking tokens also match with separators removed, so searching
/// `2a37` finds `2A37`, and `00 48` finds a payload shown as `0048`.
public struct SearchMatcher: Sendable {
    public let tokens: [String]

    public init(_ query: String) {
        tokens = query
            .split(whereSeparator: \.isWhitespace)
            .map { Self.fold(String($0)) }
            .filter { !$0.isEmpty }
    }

    public var isEmpty: Bool { tokens.isEmpty }

    public func matches(_ text: String) -> Bool {
        guard !tokens.isEmpty else { return true }
        let haystack = Self.fold(text)
        let compact = haystack.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        return tokens.allSatisfy { haystack.contains($0) || compact.contains($0) }
    }

    public func matches(any fields: [String]) -> Bool {
        matches(fields.joined(separator: " "))
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
