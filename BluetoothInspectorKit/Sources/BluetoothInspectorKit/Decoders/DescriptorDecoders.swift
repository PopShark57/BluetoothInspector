import Foundation

/// GATT descriptor decoders, plus the Characteristic Presentation Format model
/// used to decode self-describing vendor characteristics.
enum DescriptorDecoders {
    static let all: [any PayloadDecoder] = [
        extendedProperties, userDescription, clientConfiguration, serverConfiguration, presentationFormat, reportReference,
    ]

    static let extendedProperties = ClosureDecoder(name: "Characteristic Extended Properties", uuids: [0x2900]) { data in
        var reader = ByteReader(data)
        guard let bits = reader.readUInt16() else { return nil }
        let names = DecodeFormat.flags(UInt64(bits), names: [0: "Reliable Write", 1: "Writable Auxiliaries"])
        return DecodedValue(summary: names.isEmpty ? "No extended properties" : names.joined(separator: ", "), decoder: "Extended Properties")
    }

    static let userDescription = ClosureDecoder(name: "Characteristic User Description", uuids: [0x2901]) { data in
        guard let text = ByteFormatter.utf8(data) else { return nil }
        return DecodedValue(summary: "“\(text)”", decoder: "User Description")
    }

    /// 0x2902 CCCD. CoreBluetooth manages this descriptor itself through
    /// `setNotifyValue(_:for:)`; apps are not allowed to write it directly.
    static let clientConfiguration = ClosureDecoder(name: "Client Characteristic Configuration", uuids: [0x2902]) { data in
        var reader = ByteReader(data)
        guard let bits = reader.readUInt16() else { return nil }
        let names = DecodeFormat.flags(UInt64(bits), names: [0: "Notifications enabled", 1: "Indications enabled"])
        return DecodedValue(summary: names.isEmpty ? "Notifications and indications disabled" : names.joined(separator: ", "), decoder: "CCCD")
    }

    static let serverConfiguration = ClosureDecoder(name: "Server Characteristic Configuration", uuids: [0x2903]) { data in
        var reader = ByteReader(data)
        guard let bits = reader.readUInt16() else { return nil }
        return DecodedValue(summary: bits & 0x01 != 0 ? "Broadcasts enabled" : "Broadcasts disabled", decoder: "SCCD")
    }

    static let presentationFormat = ClosureDecoder(name: "Characteristic Presentation Format", uuids: [0x2904]) { data in
        guard let format = PresentationFormat(data: data) else { return nil }
        return DecodedValue(summary: format.summary, fields: format.fields, decoder: "Presentation Format")
    }

    /// 0x2908 Report Reference (HID).
    static let reportReference = ClosureDecoder(name: "Report Reference", uuids: [0x2908]) { data in
        var reader = ByteReader(data)
        guard let id = reader.readUInt8(), let type = reader.readUInt8() else { return nil }
        let types = [1: "Input", 2: "Output", 3: "Feature"]
        return DecodedValue(summary: "Report ID \(id), \(types[Int(type)] ?? "Reserved (\(type))")", decoder: "Report Reference")
    }
}

/// Characteristic Presentation Format descriptor (0x2904): format, exponent,
/// unit, namespace, description.
public struct PresentationFormat: Hashable, Codable, Sendable {
    public let format: UInt8
    public let exponent: Int8
    public let unit: UInt16
    public let namespace: UInt8
    public let descriptionID: UInt16

    public init?(data: Data) {
        var reader = ByteReader(data)
        guard data.count == 7, let format = reader.readUInt8(), let exponent = reader.readInt8(),
              let unit = reader.readUInt16(), let namespace = reader.readUInt8(),
              let description = reader.readUInt16() else { return nil }
        self.format = format
        self.exponent = exponent
        self.unit = unit
        self.namespace = namespace
        self.descriptionID = description
    }

    static let formatNames: [UInt8: String] = [
        0x01: "boolean", 0x02: "2bit", 0x03: "nibble", 0x04: "uint8", 0x05: "uint12", 0x06: "uint16",
        0x07: "uint24", 0x08: "uint32", 0x09: "uint48", 0x0A: "uint64", 0x0B: "uint128", 0x0C: "sint8",
        0x0D: "sint12", 0x0E: "sint16", 0x0F: "sint24", 0x10: "sint32", 0x11: "sint48", 0x12: "sint64",
        0x13: "sint128", 0x14: "float32", 0x15: "float64", 0x16: "SFLOAT", 0x17: "FLOAT", 0x18: "duint16",
        0x19: "utf8s", 0x1A: "utf16s", 0x1B: "struct", 0x1C: "medfloat32",
    ]

    public var formatName: String { Self.formatNames[format] ?? String(format: "Reserved (0x%02X)", format) }

    /// Unit name without the `org.bluetooth.unit.` noise.
    public var unitName: String {
        AssignedNumbers.unitName(unit) ?? String(format: "0x%04X", unit)
    }

    /// Short unit symbol for common units, falling back to the SIG name.
    public var unitSymbol: String {
        let symbols: [UInt16: String] = [
            0x2700: "", 0x2701: "m", 0x2702: "kg", 0x2703: "s", 0x2704: "A", 0x2705: "K", 0x272F: "°C",
            0x2724: "Pa", 0x2728: "V", 0x27AD: "%", 0x2726: "W", 0x27A7: "mph", 0x27AF: "BPM", 0x2763: "°",
            0x2712: "m/s", 0x27AE: "‰", 0x2781: "mmHg", 0x27AC: "°F", 0x27A6: "km/h", 0x2722: "Hz",
            0x2731: "lx", 0x27C3: "dB", 0x27C4: "ppm",
        ]
        return symbols[unit] ?? unitName
    }

    public var summary: String { "\(formatName), exponent \(exponent), unit \(unitName)" }

    public var fields: [DecodedValue.Field] {
        [
            .init("Format", formatName),
            .init("Exponent", "\(exponent)"),
            .init("Unit", "\(unitName) (\(String(format: "0x%04X", unit)))"),
            .init("Namespace", namespace == 1 ? "Bluetooth SIG" : "\(namespace)"),
            .init("Description", String(format: "0x%04X", descriptionID)),
        ]
    }

    /// Applies the format to a characteristic value: value × 10^exponent + unit.
    public func decode(_ data: Data) -> DecodedValue? {
        var reader = ByteReader(data)
        let number: Double?
        switch format {
        case 0x01: return reader.readUInt8().map { DecodedValue(summary: $0 == 0 ? "false" : "true", decoder: "Presentation Format") }
        case 0x04: number = reader.readUInt8().map(Double.init)
        case 0x06: number = reader.readUInt16().map(Double.init)
        case 0x07: number = reader.readUInt24().map(Double.init)
        case 0x08: number = reader.readUInt32().map(Double.init)
        case 0x09: number = reader.readUInt48().map(Double.init)
        case 0x0A: number = reader.readUInt64().map(Double.init)
        case 0x0C: number = reader.readInt8().map(Double.init)
        case 0x0E: number = reader.readInt16().map(Double.init)
        case 0x0F: number = reader.readInt24().map(Double.init)
        case 0x10: number = reader.readInt32().map(Double.init)
        case 0x12: number = reader.readUInt64().map { Double(Int64(bitPattern: $0)) }
        case 0x14: number = reader.readUInt32().map { Double(Float(bitPattern: $0)) }
        case 0x15: number = reader.readUInt64().map { Double(bitPattern: $0) }
        case 0x16: number = reader.readSFloat()?.doubleValue
        case 0x17: number = reader.readFloat32()?.doubleValue
        case 0x19:
            return ByteFormatter.utf8(data).map { DecodedValue(summary: "“\($0)”", decoder: "Presentation Format") }
        default:
            return nil
        }
        guard let number else { return nil }
        // IEEE float formats already carry their own scale.
        let scaled = [0x14, 0x15, 0x16, 0x17].contains(format) ? number : number * pow(10, Double(exponent))
        let decimals = max(0, -Int(exponent))
        let text = [0x14, 0x15, 0x16, 0x17].contains(format) ? MedicalFloat.format(scaled) : DecodeFormat.number(scaled, decimals: decimals)
        let unitText = unitSymbol.isEmpty ? "" : " \(unitSymbol)"
        return DecodedValue(summary: "\(text)\(unitText)", fields: [.init("Presentation", summary)], decoder: "Presentation Format")
    }
}
