import Foundation

/// GAP, GATT, Device Information, time and HID characteristic decoders.
enum GenericDecoders {
    static let all: [any PayloadDecoder] = [
        utf8Strings, appearance, preferredConnectionParameters, serviceChanged, txPowerLevel, alertLevel,
        systemID, pnpID, currentTime, dateTime, booleanFlags, databaseHash, hidInformation, protocolMode,
    ]

    /// Device Name and the Device Information string characteristics.
    static let utf8Strings = ClosureDecoder(
        name: "UTF-8 String",
        uuids: [0x2A00, 0x2A24, 0x2A25, 0x2A26, 0x2A27, 0x2A28, 0x2A29, 0x2A87, 0x2A8A, 0x2A90]
    ) { data in
        guard let text = ByteFormatter.utf8(data) else { return nil }
        // Some firmware pads strings with NULs; show them trimmed.
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        return DecodedValue(summary: "“\(trimmed)”", decoder: "UTF-8 String")
    }

    /// 0x2A01 Appearance: 10-bit category + 6-bit subcategory.
    static let appearance = ClosureDecoder(name: "Appearance", uuids: [0x2A01]) { data in
        var reader = ByteReader(data)
        guard let value = reader.readUInt16() else { return nil }
        let name = AssignedNumbers.appearanceName(value) ?? "Unknown"
        return DecodedValue(summary: "Appearance: \(name)", fields: [
            .init("Value", DecodeFormat.hex16(value)),
            .init("Category", "\(value >> 6)"),
            .init("Subcategory", "\(value & 0x3F)"),
        ], decoder: "Appearance")
    }

    /// 0x2A04 Peripheral Preferred Connection Parameters.
    static let preferredConnectionParameters = ClosureDecoder(name: "Peripheral Preferred Connection Parameters", uuids: [0x2A04]) { data in
        var reader = ByteReader(data)
        guard let minimum = reader.readUInt16(), let maximum = reader.readUInt16(),
              let latency = reader.readUInt16(), let timeout = reader.readUInt16() else { return nil }
        func interval(_ value: UInt16) -> String {
            value == 0xFFFF ? "no preference" : DecodeFormat.number(Double(value) * 1.25, decimals: 2) + " ms"
        }
        return DecodedValue(summary: "Interval \(interval(minimum))–\(interval(maximum)), latency \(latency)", fields: [
            .init("Minimum Connection Interval", interval(minimum)),
            .init("Maximum Connection Interval", interval(maximum)),
            .init("Peripheral Latency", "\(latency) events"),
            .init("Supervision Timeout", timeout == 0xFFFF ? "no preference" : "\(Int(timeout) * 10) ms"),
        ], decoder: "Peripheral Preferred Connection Parameters")
    }

    static let serviceChanged = ClosureDecoder(name: "Service Changed", uuids: [0x2A05]) { data in
        var reader = ByteReader(data)
        guard let start = reader.readUInt16(), let end = reader.readUInt16() else { return nil }
        return DecodedValue(summary: "Service Changed: handles \(DecodeFormat.hex16(start))–\(DecodeFormat.hex16(end))", decoder: "Service Changed")
    }

    static let txPowerLevel = ClosureDecoder(name: "Tx Power Level", uuids: [0x2A07]) { data in
        guard data.count == 1, let value = data.first else { return nil }
        return DecodedValue(summary: "Tx Power Level: \(Int8(bitPattern: value)) dBm", decoder: "Tx Power Level")
    }

    static let alertLevel = ClosureDecoder(name: "Alert Level", uuids: [0x2A06]) { data in
        guard let value = data.first else { return nil }
        let names = ["No Alert", "Mild Alert", "High Alert"]
        return DecodedValue(summary: "Alert Level: \(names[safe: Int(value)] ?? "Reserved (\(value))")", decoder: "Alert Level")
    }

    /// 0x2A23 System ID: 40-bit manufacturer-defined identifier + 24-bit OUI.
    static let systemID = ClosureDecoder(name: "System ID", uuids: [0x2A23]) { data in
        var reader = ByteReader(data)
        guard data.count == 8, let identifier = reader.readBytes(5), let oui = reader.readBytes(3) else { return nil }
        let ouiText = oui.reversed().map { String(format: "%02X", $0) }.joined(separator: ":")
        return DecodedValue(summary: "System ID: OUI \(ouiText)", fields: [
            .init("Manufacturer Identifier", Data(identifier.reversed()).hexString),
            .init("Organizationally Unique Identifier", ouiText),
        ], decoder: "System ID")
    }

    /// 0x2A50 PnP ID: vendor ID source, vendor ID, product ID, product version.
    static let pnpID = ClosureDecoder(name: "PnP ID", uuids: [0x2A50]) { data in
        var reader = ByteReader(data)
        guard let source = reader.readUInt8(), let vendor = reader.readUInt16(),
              let product = reader.readUInt16(), let version = reader.readUInt16() else { return nil }
        let info = PnPInformation(vendorIDSource: UInt16(source), vendorID: vendor, productID: product, version: version)
        return DecodedValue(summary: "PnP ID: \(info.vendorDescription), product \(DecodeFormat.hex16(product))",
                            fields: info.fields, decoder: "PnP ID")
    }

    /// 0x2A2B Current Time: Exact Time 256 + Adjust Reason.
    static let currentTime = ClosureDecoder(name: "Current Time", uuids: [0x2A2B]) { data in
        var reader = ByteReader(data)
        guard let stamp = DecodeFormat.dateTime(&reader), let weekday = reader.readUInt8(),
              let fractions = reader.readUInt8() else { return nil }
        let days = ["Unknown", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
        var fields: [DecodedValue.Field] = [
            .init("Date Time", stamp),
            .init("Day of Week", days[safe: Int(weekday)] ?? "Reserved"),
            .init("Fractions256", "\(fractions)/256 s"),
        ]
        if let reason = reader.readUInt8() {
            let reasons = DecodeFormat.flags(UInt64(reason), names: [0: "Manual time update", 1: "External reference time update",
                                                                     2: "Change of time zone", 3: "Change of DST"])
            fields.append(.init("Adjust Reason", reasons.isEmpty ? "None" : reasons.joined(separator: ", ")))
        }
        return DecodedValue(summary: "Current Time: \(stamp)", fields: fields, decoder: "Current Time")
    }

    static let dateTime = ClosureDecoder(name: "Date Time", uuids: [0x2A08]) { data in
        var reader = ByteReader(data)
        guard let stamp = DecodeFormat.dateTime(&reader) else { return nil }
        return DecodedValue(summary: "Date Time: \(stamp)", decoder: "Date Time")
    }

    /// Single-byte boolean characteristics.
    static let booleanFlags = ClosureDecoder(name: "Boolean", uuids: [0x2AA6, 0x2AC9]) { data in
        guard data.count == 1, let value = data.first else { return nil }
        let text = value == 0 ? "No (0)" : value == 1 ? "Yes (1)" : "Reserved (\(value))"
        return DecodedValue(summary: text, decoder: "Boolean")
    }

    static let databaseHash = ClosureDecoder(name: "Database Hash", uuids: [0x2B2A]) { data in
        guard data.count == 16 else { return nil }
        return DecodedValue(summary: "Database Hash: \(ByteFormatter.compactHex(data))", decoder: "Database Hash")
    }

    /// 0x2A4A HID Information. (macOS normally hides the HID service from apps;
    /// this decoder exists for devices that expose it anyway.)
    static let hidInformation = ClosureDecoder(name: "HID Information", uuids: [0x2A4A]) { data in
        var reader = ByteReader(data)
        guard let bcd = reader.readUInt16(), let country = reader.readUInt8(), let flags = reader.readUInt8() else { return nil }
        let flagNames = DecodeFormat.flags(UInt64(flags), names: [0: "RemoteWake", 1: "NormallyConnectable"])
        return DecodedValue(summary: String(format: "HID %X.%02X", bcd >> 8, bcd & 0xFF), fields: [
            .init("bcdHID", DecodeFormat.hex16(bcd)),
            .init("Country Code", "\(country)"),
            .init("Flags", flagNames.isEmpty ? "none" : flagNames.joined(separator: ", ")),
        ], decoder: "HID Information")
    }

    static let protocolMode = ClosureDecoder(name: "Protocol Mode", uuids: [0x2A4E]) { data in
        guard let value = data.first else { return nil }
        let name = value == 0 ? "Boot Protocol" : value == 1 ? "Report Protocol" : "Reserved (\(value))"
        return DecodedValue(summary: "Protocol Mode: \(name)", decoder: "Protocol Mode")
    }
}

/// Device ID / PnP information shared by the BLE PnP ID characteristic and the
/// Classic SDP PnP Information record.
public struct PnPInformation: Hashable, Codable, Sendable {
    public let vendorIDSource: UInt16
    public let vendorID: UInt16
    public let productID: UInt16
    public let version: UInt16

    public init(vendorIDSource: UInt16, vendorID: UInt16, productID: UInt16, version: UInt16) {
        self.vendorIDSource = vendorIDSource
        self.vendorID = vendorID
        self.productID = productID
        self.version = version
    }

    public var sourceName: String {
        switch vendorIDSource {
        case 1: "Bluetooth SIG"
        case 2: "USB Implementer's Forum"
        default: "Reserved (\(vendorIDSource))"
        }
    }

    /// Vendor name is only resolvable for SIG-assigned IDs; USB vendor IDs are
    /// shown numerically because no USB-IF table is bundled.
    public var vendorName: String? {
        vendorIDSource == 1 ? AssignedNumbers.companyName(vendorID) : nil
    }

    public var vendorDescription: String {
        let id = String(format: "0x%04X", vendorID)
        if let vendorName { return "\(vendorName) (\(id))" }
        return "\(sourceName) vendor \(id)"
    }

    public var versionString: String {
        // Version is BCD-like 0xJJMN → JJ.M.N.
        String(format: "%X.%X.%X", version >> 8, (version >> 4) & 0x0F, version & 0x0F)
    }

    public var fields: [DecodedValue.Field] {
        [
            .init("Vendor ID Source", sourceName),
            .init("Vendor", vendorDescription),
            .init("Product ID", String(format: "0x%04X", productID)),
            .init("Product Version", "\(versionString) (\(String(format: "0x%04X", version)))"),
        ]
    }
}
