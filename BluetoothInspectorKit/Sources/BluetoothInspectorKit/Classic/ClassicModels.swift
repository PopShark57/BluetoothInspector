import Foundation

/// Everything IOBluetooth exposes about a Classic (BR/EDR) device.
public struct ClassicDeviceInfo: Hashable, Codable, Sendable {
    /// Public BD_ADDR in IOBluetooth's `xx-xx-xx-xx-xx-xx` form.
    public var address: String
    public var name: String?
    public var classOfDevice: ClassOfDevice?
    public var isPaired: Bool
    public var isConnected: Bool
    public var isFavorite: Bool
    /// Only meaningful while a baseband connection exists.
    public var rssi: Int?
    public var lastInquiryUpdate: Date?
    public var lastNameUpdate: Date?
    public var lastServicesUpdate: Date?
    /// Result of the last SDP query (cached by the system if not re-queried).
    public var serviceRecords: [SDPServiceRecord]
    /// How this device became known to us.
    public var sources: Set<Source>

    public enum Source: String, Codable, Sendable, CaseIterable {
        case paired
        case recent
        case inquiry
        case connected
    }

    public init(
        address: String,
        name: String? = nil,
        classOfDevice: ClassOfDevice? = nil,
        isPaired: Bool = false,
        isConnected: Bool = false,
        isFavorite: Bool = false,
        rssi: Int? = nil,
        lastInquiryUpdate: Date? = nil,
        lastNameUpdate: Date? = nil,
        lastServicesUpdate: Date? = nil,
        serviceRecords: [SDPServiceRecord] = [],
        sources: Set<Source> = []
    ) {
        self.address = ClassicDeviceInfo.normalize(address: address)
        self.name = name
        self.classOfDevice = classOfDevice
        self.isPaired = isPaired
        self.isConnected = isConnected
        self.isFavorite = isFavorite
        self.rssi = rssi
        self.lastInquiryUpdate = lastInquiryUpdate
        self.lastNameUpdate = lastNameUpdate
        self.lastServicesUpdate = lastServicesUpdate
        self.serviceRecords = serviceRecords
        self.sources = sources
    }

    /// Uppercase, colon separated (`AA:BB:CC:DD:EE:FF`) regardless of input form.
    public static func normalize(address: String) -> String {
        let hex = address.uppercased().filter(\.isHexDigit)
        guard hex.count == 12 else { return address.uppercased() }
        let chars = Array(hex)
        return stride(from: 0, to: 12, by: 2).map { String(chars[$0...$0 + 1]) }.joined(separator: ":")
    }

    /// First three octets: the IEEE OUI of the device's manufacturer (for
    /// public addresses). No OUI database is bundled; the value is shown raw.
    public var oui: String { String(address.prefix(8)) }

    public var pnpInformation: PnPInformation? {
        serviceRecords.lazy.compactMap(\.pnpInformation).first
    }

    public var profileNames: [String] {
        var seen = Set<String>()
        return serviceRecords.flatMap(\.serviceClassIDs).compactMap { uuid in
            let name = uuid.displayName
            return seen.insert(name).inserted ? name : nil
        }
    }

    /// Merges a newer observation, keeping information the newer one lacks.
    public func merging(_ newer: ClassicDeviceInfo) -> ClassicDeviceInfo {
        var merged = newer
        merged.name = newer.name ?? name
        merged.classOfDevice = newer.classOfDevice ?? classOfDevice
        merged.rssi = newer.rssi ?? rssi
        merged.lastInquiryUpdate = newer.lastInquiryUpdate ?? lastInquiryUpdate
        merged.lastNameUpdate = newer.lastNameUpdate ?? lastNameUpdate
        merged.lastServicesUpdate = newer.lastServicesUpdate ?? lastServicesUpdate
        merged.serviceRecords = newer.serviceRecords.isEmpty ? serviceRecords : newer.serviceRecords
        merged.sources = sources.union(newer.sources)
        return merged
    }
}

/// An SDP data element (Core Spec Vol 3 Part B §3).
public indirect enum SDPDataElement: Hashable, Sendable {
    case null
    case unsignedInteger(UInt64, bytes: Int)
    case signedInteger(Int64, bytes: Int)
    /// Integers wider than 64 bits (128-bit) are kept as raw bytes.
    case largeInteger(Data, signed: Bool)
    case uuid(BluetoothUUID)
    case text(String)
    case boolean(Bool)
    case sequence([SDPDataElement])
    case alternative([SDPDataElement])
    case url(String)
    /// Text that was not valid UTF-8, or an element type IOBluetooth reported
    /// that this app does not interpret.
    case raw(Data, typeDescriptor: UInt8)

    public var typeName: String {
        switch self {
        case .null: "Nil"
        case .unsignedInteger(_, let bytes): "UInt\(bytes * 8)"
        case .signedInteger(_, let bytes): "Int\(bytes * 8)"
        case .largeInteger(let data, let signed): "\(signed ? "Int" : "UInt")\(data.count * 8)"
        case .uuid: "UUID"
        case .text: "String"
        case .boolean: "Bool"
        case .sequence: "Sequence"
        case .alternative: "Alternative"
        case .url: "URL"
        case .raw(_, let type): "Type \(type)"
        }
    }

    public var displayValue: String {
        switch self {
        case .null: return "nil"
        case .unsignedInteger(let value, let bytes): return String(format: "0x%0\(bytes * 2)llX", value) + " (\(value))"
        case .signedInteger(let value, _): return "\(value)"
        case .largeInteger(let data, _): return "0x" + ByteFormatter.compactHex(data)
        case .uuid(let uuid): return uuid.displayName
        case .text(let text): return "“\(text)”"
        case .boolean(let value): return value ? "true" : "false"
        case .sequence(let items): return "Sequence (\(items.count))"
        case .alternative(let items): return "Alternative (\(items.count))"
        case .url(let url): return url
        case .raw(let data, _): return data.hexString
        }
    }

    public var children: [SDPDataElement]? {
        switch self {
        case .sequence(let items), .alternative(let items): items
        default: nil
        }
    }

    public var uintValue: UInt64? {
        if case .unsignedInteger(let value, _) = self { return value }
        return nil
    }

    public var uuidValue: BluetoothUUID? {
        if case .uuid(let uuid) = self { return uuid }
        return nil
    }

    public var stringValue: String? {
        switch self {
        case .text(let text), .url(let text): text
        default: nil
        }
    }

    /// Indented multi-line rendering for exports and copying.
    public func render(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        guard let children else { return "\(pad)\(typeName): \(displayValue)" }
        return ([pad + displayValue] + children.map { $0.render(indent: indent + 1) }).joined(separator: "\n")
    }
}

extension SDPDataElement: Codable {
    private enum CodingKeys: String, CodingKey { case type, value, items, bytes }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .null:
            try container.encode("nil", forKey: .type)
        case .unsignedInteger(let value, let bytes):
            try container.encode("uint", forKey: .type)
            try container.encode(value, forKey: .value)
            try container.encode(bytes, forKey: .bytes)
        case .signedInteger(let value, let bytes):
            try container.encode("int", forKey: .type)
            try container.encode(value, forKey: .value)
            try container.encode(bytes, forKey: .bytes)
        case .largeInteger(let data, let signed):
            try container.encode(signed ? "int128" : "uint128", forKey: .type)
            try container.encode(ByteFormatter.compactHex(data), forKey: .value)
        case .uuid(let uuid):
            try container.encode("uuid", forKey: .type)
            try container.encode(uuid, forKey: .value)
        case .text(let text):
            try container.encode("string", forKey: .type)
            try container.encode(text, forKey: .value)
        case .boolean(let value):
            try container.encode("bool", forKey: .type)
            try container.encode(value, forKey: .value)
        case .sequence(let items):
            try container.encode("sequence", forKey: .type)
            try container.encode(items, forKey: .items)
        case .alternative(let items):
            try container.encode("alternative", forKey: .type)
            try container.encode(items, forKey: .items)
        case .url(let url):
            try container.encode("url", forKey: .type)
            try container.encode(url, forKey: .value)
        case .raw(let data, let type):
            try container.encode("raw\(type)", forKey: .type)
            try container.encode(ByteFormatter.compactHex(data), forKey: .value)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "nil": self = .null
        case "uint": self = .unsignedInteger(try container.decode(UInt64.self, forKey: .value), bytes: try container.decode(Int.self, forKey: .bytes))
        case "int": self = .signedInteger(try container.decode(Int64.self, forKey: .value), bytes: try container.decode(Int.self, forKey: .bytes))
        case "int128", "uint128":
            let data = (try? HexParser.parse(try container.decode(String.self, forKey: .value))) ?? Data()
            self = .largeInteger(data, signed: type == "int128")
        case "uuid": self = .uuid(try container.decode(BluetoothUUID.self, forKey: .value))
        case "string": self = .text(try container.decode(String.self, forKey: .value))
        case "bool": self = .boolean(try container.decode(Bool.self, forKey: .value))
        case "sequence": self = .sequence(try container.decode([SDPDataElement].self, forKey: .items))
        case "alternative": self = .alternative(try container.decode([SDPDataElement].self, forKey: .items))
        case "url": self = .url(try container.decode(String.self, forKey: .value))
        default:
            let data = (try? HexParser.parse(try container.decode(String.self, forKey: .value))) ?? Data()
            self = .raw(data, typeDescriptor: UInt8(type.dropFirst(3)) ?? 0)
        }
    }
}

public struct SDPAttribute: Hashable, Codable, Sendable, Identifiable {
    public let id: UInt16
    public let value: SDPDataElement

    public init(id: UInt16, value: SDPDataElement) {
        self.id = id
        self.value = value
    }

    /// Universal attribute names; 0x0100+ names assume the default language
    /// base (0x0100), which is what virtually every device uses.
    public static let universalNames: [UInt16: String] = [
        0x0000: "ServiceRecordHandle", 0x0001: "ServiceClassIDList", 0x0002: "ServiceRecordState",
        0x0003: "ServiceID", 0x0004: "ProtocolDescriptorList", 0x0005: "BrowseGroupList",
        0x0006: "LanguageBaseAttributeIDList", 0x0007: "ServiceInfoTimeToLive", 0x0008: "ServiceAvailability",
        0x0009: "BluetoothProfileDescriptorList", 0x000A: "DocumentationURL", 0x000B: "ClientExecutableURL",
        0x000C: "IconURL", 0x000D: "AdditionalProtocolDescriptorLists",
        0x0100: "ServiceName", 0x0101: "ServiceDescription", 0x0102: "ProviderName",
    ]

    /// Names for attributes of the PnP Information (Device ID) record.
    public static let pnpNames: [UInt16: String] = [
        0x0200: "SpecificationID", 0x0201: "VendorID", 0x0202: "ProductID", 0x0203: "Version",
        0x0204: "PrimaryRecord", 0x0205: "VendorIDSource",
    ]

    public func name(inPnPRecord: Bool = false) -> String {
        if inPnPRecord, let name = Self.pnpNames[id] { return name }
        if let name = Self.universalNames[id] { return name }
        return id == 0x0311 ? "SupportedFeatures" : "Attribute"
    }
}

/// One SDP service record from a Classic device.
public struct SDPServiceRecord: Hashable, Codable, Sendable, Identifiable {
    public let attributes: [SDPAttribute]
    /// Name as IOBluetooth resolved it via the language base.
    public let serviceName: String?

    public init(attributes: [SDPAttribute], serviceName: String? = nil) {
        self.attributes = attributes.sorted { $0.id < $1.id }
        self.serviceName = serviceName ?? attributes.first { $0.id == 0x0100 }?.value.stringValue
    }

    public var id: String {
        if let handle = attribute(0x0000)?.uintValue { return String(format: "%08llX", handle) }
        return serviceClassIDs.map(\.uuidString).joined(separator: ",") + (serviceName ?? "")
    }

    public func attribute(_ id: UInt16) -> SDPDataElement? {
        attributes.first { $0.id == id }?.value
    }

    public var serviceClassIDs: [BluetoothUUID] {
        attribute(0x0001)?.children?.compactMap(\.uuidValue) ?? []
    }

    public var isPnPInformation: Bool {
        serviceClassIDs.contains(BluetoothUUID(uint16: 0x1200))
    }

    /// Protocol stack, e.g. `[L2CAP, RFCOMM channel 3]`.
    public var protocolDescriptors: [(protocol: BluetoothUUID, parameters: [SDPDataElement])] {
        guard let list = attribute(0x0004)?.children else { return [] }
        return list.compactMap { element in
            guard let items = element.children, let uuid = items.first?.uuidValue else { return nil }
            return (uuid, Array(items.dropFirst()))
        }
    }

    public var rfcommChannel: UInt8? {
        protocolDescriptors.first { $0.protocol == BluetoothUUID(uint16: 0x0003) }?
            .parameters.first?.uintValue.map { UInt8(truncatingIfNeeded: $0) }
    }

    public var l2capPSM: UInt16? {
        protocolDescriptors.first { $0.protocol == BluetoothUUID(uint16: 0x0100) }?
            .parameters.first?.uintValue.map { UInt16(truncatingIfNeeded: $0) }
    }

    /// Profile UUID and version (`0x0102` → 1.2).
    public var profiles: [(uuid: BluetoothUUID, version: String)] {
        guard let list = attribute(0x0009)?.children else { return [] }
        return list.compactMap { element in
            guard let items = element.children, let uuid = items.first?.uuidValue else { return nil }
            let version = items.dropFirst().first?.uintValue.map { String(format: "%d.%d", $0 >> 8, $0 & 0xFF) } ?? "?"
            return (uuid, version)
        }
    }

    public var pnpInformation: PnPInformation? {
        guard isPnPInformation,
              let vendor = attribute(0x0201)?.uintValue,
              let product = attribute(0x0202)?.uintValue,
              let version = attribute(0x0203)?.uintValue else { return nil }
        let source = attribute(0x0205)?.uintValue ?? 1
        return PnPInformation(vendorIDSource: UInt16(truncatingIfNeeded: source), vendorID: UInt16(truncatingIfNeeded: vendor),
                              productID: UInt16(truncatingIfNeeded: product), version: UInt16(truncatingIfNeeded: version))
    }

    public var title: String {
        if let serviceName, !serviceName.isEmpty { return serviceName }
        return serviceClassIDs.first?.displayName ?? "Service Record \(id)"
    }

    public var summary: String {
        var parts: [String] = []
        if let rfcommChannel { parts.append("RFCOMM \(rfcommChannel)") }
        if let l2capPSM { parts.append(String(format: "PSM 0x%04X", l2capPSM)) }
        parts += profiles.map { "\($0.uuid.displayName) v\($0.version)" }
        return parts.joined(separator: " · ")
    }
}
