import BluetoothInspectorKit
import SwiftUI
import UniformTypeIdentifiers

/// In-memory file handed to SwiftUI's `fileExporter`.
struct ExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json, .commaSeparatedText, .plainText]

    var data: Data
    var contentType: UTType

    init(data: Data, format: ExportFormat) {
        self.data = data
        self.contentType = Self.contentType(for: format)
    }

    init(text: String, format: ExportFormat) {
        self.init(data: Data(text.utf8), format: format)
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        contentType = configuration.contentType
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }

    static func contentType(for format: ExportFormat) -> UTType {
        switch format {
        case .json: .json
        case .csv: .commaSeparatedText
        case .text: .plainText
        }
    }

    /// `bluetooth-inspector-<name>-20260926-184201.json`
    static func filename(_ name: String, format: ExportFormat, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let safe = name.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { result, character in
                if character == "-", result.hasSuffix("-") { return }
                result.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "bluetooth-inspector-\(safe.isEmpty ? "export" : safe)-\(formatter.string(from: date)).\(format.fileExtension)"
    }
}
