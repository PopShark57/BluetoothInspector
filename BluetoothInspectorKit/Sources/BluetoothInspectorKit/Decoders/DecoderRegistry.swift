import Foundation

/// Interprets the value of one or more characteristics or descriptors.
///
/// This is the extension point for protocol decoders: conform a type (or use
/// `ClosureDecoder`) and register it with a `DecoderRegistry`. Decoders must be
/// total — return `nil` for payloads they do not understand rather than
/// guessing, so the UI can fall back to raw bytes.
public protocol PayloadDecoder: Sendable {
    /// Short name shown as the decoder's provenance.
    var name: String { get }
    /// UUIDs this decoder handles.
    var uuids: Set<BluetoothUUID> { get }
    func decode(_ data: Data, uuid: BluetoothUUID) -> DecodedValue?
}

/// Convenience decoder built from a closure.
public struct ClosureDecoder: PayloadDecoder {
    public let name: String
    public let uuids: Set<BluetoothUUID>
    private let body: @Sendable (Data) -> DecodedValue?

    public init(name: String, uuids: [UInt16], decode: @escaping @Sendable (Data) -> DecodedValue?) {
        self.name = name
        self.uuids = Set(uuids.map(BluetoothUUID.init(uint16:)))
        self.body = decode
    }

    public init(name: String, uuids: Set<BluetoothUUID>, decode: @escaping @Sendable (Data) -> DecodedValue?) {
        self.name = name
        self.uuids = uuids
        self.body = decode
    }

    public func decode(_ data: Data, uuid: BluetoothUUID) -> DecodedValue? { body(data) }
}

/// Maps UUIDs to decoders. Value type so a customized copy can be built and
/// swapped in without affecting other users of `standard`.
public struct DecoderRegistry: Sendable {
    private var characteristicDecoders: [BluetoothUUID: any PayloadDecoder] = [:]
    private var descriptorDecoders: [BluetoothUUID: any PayloadDecoder] = [:]

    public init() {}

    /// Every decoder that ships with the app.
    public static let standard: DecoderRegistry = {
        var registry = DecoderRegistry()
        for decoder in GenericDecoders.all + HealthDecoders.all + FitnessDecoders.all + EnvironmentalDecoders.all {
            registry.register(characteristic: decoder)
        }
        for decoder in DescriptorDecoders.all {
            registry.register(descriptor: decoder)
        }
        return registry
    }()

    /// Registers (or replaces) a characteristic decoder for each of its UUIDs.
    public mutating func register(characteristic decoder: any PayloadDecoder) {
        for uuid in decoder.uuids { characteristicDecoders[uuid] = decoder }
    }

    public mutating func register(descriptor decoder: any PayloadDecoder) {
        for uuid in decoder.uuids { descriptorDecoders[uuid] = decoder }
    }

    public func hasDecoder(forCharacteristic uuid: BluetoothUUID) -> Bool {
        characteristicDecoders[uuid] != nil
    }

    public var characteristicUUIDs: [BluetoothUUID] { characteristicDecoders.keys.sorted() }

    public func decode(characteristic uuid: BluetoothUUID, data: Data) -> DecodedValue? {
        characteristicDecoders[uuid]?.decode(data, uuid: uuid)
    }

    /// Decodes a characteristic, falling back to its Presentation Format
    /// descriptor (0x2904) when no specification decoder exists. That fallback
    /// is how vendor characteristics that describe themselves get decoded.
    public func decode(characteristic uuid: BluetoothUUID, data: Data, presentationFormat: PresentationFormat?) -> DecodedValue? {
        if let decoded = decode(characteristic: uuid, data: data) { return decoded }
        return presentationFormat?.decode(data)
    }

    public func decode(descriptor uuid: BluetoothUUID, data: Data) -> DecodedValue? {
        descriptorDecoders[uuid]?.decode(data, uuid: uuid)
    }
}

// MARK: - Helpers shared by the decoder families

enum DecodeFormat {
    static func number(_ value: Double, decimals: Int) -> String {
        String(format: "%.\(decimals)f", value)
    }

    static func flags(_ value: UInt64, names: [Int: String]) -> [String] {
        names.keys.sorted().compactMap { bit in value & (1 << UInt64(bit)) != 0 ? names[bit] : nil }
    }

    static func hex8(_ value: UInt8) -> String { String(format: "0x%02X", value) }
    static func hex16(_ value: UInt16) -> String { String(format: "0x%04X", value) }

    /// Date Time characteristic layout (0x2A08), embedded in many measurements.
    static func dateTime(_ reader: inout ByteReader) -> String? {
        guard let year = reader.readUInt16(), let month = reader.readUInt8(), let day = reader.readUInt8(),
              let hour = reader.readUInt8(), let minute = reader.readUInt8(), let second = reader.readUInt8()
        else { return nil }
        let y = year == 0 ? "????" : String(format: "%04d", year)
        let m = month == 0 ? "??" : String(format: "%02d", month)
        let d = day == 0 ? "??" : String(format: "%02d", day)
        return String(format: "%@-%@-%@ %02d:%02d:%02d", y, m, d, hour, minute, second)
    }
}

extension ByteReader {
    mutating func readInt24() -> Int32? {
        guard let raw = readUInt24() else { return nil }
        return raw & 0x80_0000 != 0 ? Int32(bitPattern: raw | 0xFF00_0000) : Int32(raw)
    }
}
