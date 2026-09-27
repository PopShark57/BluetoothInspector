import Foundation

/// Versioned, self-describing JSON export formats.
///
/// Every byte payload is exported as lowercase hex *and* decoded where
/// possible, and every UUID with its SIG name, so an export is useful to
/// another tool (or an AI assistant) without access to this app.
public enum ExportSchema {
    public static let version = 1
}

public struct ExportGenerator: Codable, Hashable, Sendable {
    public var app: String
    public var appVersion: String
    public var operatingSystem: String

    public init(app: String = "Bluetooth Inspector", appVersion: String, operatingSystem: String) {
        self.app = app
        self.appVersion = appVersion
        self.operatingSystem = operatingSystem
    }
}

public struct UUIDExport: Codable, Hashable, Sendable {
    public let uuid: String
    public let short: String
    public let name: String?

    public init(_ uuid: BluetoothUUID) {
        self.uuid = uuid.uuidString
        self.short = uuid.shortString
        self.name = uuid.sigName
    }
}

public struct DecodedExport: Codable, Hashable, Sendable {
    public let decoder: String
    public let summary: String
    public let fields: [String: String]

    public init(_ value: DecodedValue) {
        decoder = value.decoder
        summary = value.summary
        var fields: [String: String] = [:]
        for field in value.fields {
            // Keep duplicate field names distinct instead of overwriting.
            var key = field.name.trimmingCharacters(in: .whitespaces)
            var suffix = 2
            while fields[key] != nil { key = "\(field.name) \(suffix)"; suffix += 1 }
            fields[key] = field.value
        }
        self.fields = fields
    }
}

public struct DeviceSummaryExport: Codable, Hashable, Sendable {
    public var id: String
    public var identifier: String
    public var identifierKind: String
    public var transport: String
    public var name: String?
    public var customName: String?
    public var connectionState: String
    public var systemConnected: Bool
    public var rssi: Int?
    public var firstSeen: Date
    public var lastSeen: Date?
    public var manufacturer: String?
    public var txPowerLevel: Int?
    public var connectable: Bool?
    public var paired: Bool?
    public var dualModeHint: String
    public var favorite: Bool
    public var notes: String?
    public var maximumWriteLength: Int?
    public var maximumWriteWithoutResponseLength: Int?
    public var lastError: String?
}

public struct AdvertisementExport: Codable, Hashable, Sendable {
    public struct Manufacturer: Codable, Hashable, Sendable {
        public let companyID: String
        public let companyName: String?
        public let hex: String
        public let payloadHex: String
        public let decoded: DecodedExport?
    }

    public struct ServiceData: Codable, Hashable, Sendable {
        public let service: UUIDExport
        public let hex: String
        public let decoded: DecodedExport?
    }

    public struct Field: Codable, Hashable, Sendable {
        public let name: String
        public let value: String
        public let hex: String?
    }

    public var localName: String?
    public var serviceUUIDs: [UUIDExport]
    public var overflowServiceUUIDs: [UUIDExport]
    public var solicitedServiceUUIDs: [UUIDExport]
    public var manufacturerData: Manufacturer?
    public var serviceData: [ServiceData]
    public var txPowerLevel: Int?
    public var connectable: Bool?
    public var fields: [Field]
    public var packetCount: Int
    public var changeCount: Int
    public var note: String

    public init(_ advertisement: AdvertisementData, packetCount: Int = 0, changeCount: Int = 0) {
        localName = advertisement.localName
        serviceUUIDs = advertisement.serviceUUIDs.map(UUIDExport.init)
        overflowServiceUUIDs = advertisement.overflowServiceUUIDs.map(UUIDExport.init)
        solicitedServiceUUIDs = advertisement.solicitedServiceUUIDs.map(UUIDExport.init)
        if let raw = advertisement.manufacturerData {
            let parsed = ManufacturerData(data: raw)
            manufacturerData = Manufacturer(
                companyID: parsed.map { String(format: "0x%04X", $0.companyID) } ?? "n/a",
                companyName: parsed?.companyName,
                hex: ByteFormatter.compactHex(raw),
                payloadHex: parsed.map { ByteFormatter.compactHex($0.payload) } ?? "",
                decoded: parsed?.vendorDecoded.map(DecodedExport.init)
            )
        }
        serviceData = advertisement.serviceData.map {
            ServiceData(service: UUIDExport($0.uuid), hex: ByteFormatter.compactHex($0.data),
                        decoded: ServiceDataDecoder.decode(uuid: $0.uuid, data: $0.data).map(DecodedExport.init))
        }
        txPowerLevel = advertisement.txPowerLevel
        connectable = advertisement.isConnectable
        fields = advertisement.fields.map { Field(name: $0.name.trimmingCharacters(in: .whitespaces), value: $0.value, hex: $0.rawHex.isEmpty ? nil : $0.rawHex) }
        self.packetCount = packetCount
        self.changeCount = changeCount
        note = "Fields as parsed by CoreBluetooth; macOS does not expose the raw advertising PDU, AD flags or advertiser address."
    }
}

public struct ServiceExport: Codable, Hashable, Sendable {
    public let id: String
    public let service: UUIDExport
    public let primary: Bool
    public let includedServiceIDs: [String]
    public let characteristicIDs: [String]
    public let discovery: String
    public let error: String?
}

public struct DescriptorExport: Codable, Hashable, Sendable {
    public let id: String
    public let descriptor: UUIDExport
    public let hex: String?
    public let display: String?
    public let decoded: DecodedExport?
    public let error: String?
}

public struct CharacteristicExport: Codable, Hashable, Sendable {
    public let id: String
    public let serviceID: String
    public let service: UUIDExport
    public let characteristic: UUIDExport
    public let properties: [String]
    public let propertiesRaw: UInt
    public let hex: String?
    public let utf8: String?
    public let decoded: DecodedExport?
    public let valueUpdatedAt: Date?
    public let notifying: Bool
    public let descriptors: [DescriptorExport]
    public let error: String?
}

public struct ValueRecordExport: Codable, Hashable, Sendable {
    public let timestamp: Date
    public let kind: String
    public let characteristicID: String
    public let characteristic: UUIDExport
    public let hex: String
    public let byteCount: Int
    public let decoded: String?

    public init(_ record: ValueRecord) {
        timestamp = record.timestamp
        kind = record.kind.rawValue
        characteristicID = record.characteristicID.description
        characteristic = UUIDExport(record.characteristicUUID)
        hex = ByteFormatter.compactHex(record.data)
        byteCount = record.data.count
        decoded = record.decodedSummary
    }
}

public struct EventExport: Codable, Hashable, Sendable {
    public let sequence: UInt64
    public let timestamp: Date
    public let category: String
    public let deviceID: String?
    public let deviceName: String?
    public let message: String
    public let uuid: UUIDExport?
    public let hex: String?

    public init(_ event: ActivityEvent) {
        sequence = event.id
        timestamp = event.timestamp
        category = event.category.rawValue
        deviceID = event.deviceID?.rawValue
        deviceName = event.deviceName
        message = event.message
        uuid = event.uuid.map(UUIDExport.init)
        hex = event.data.map(ByteFormatter.compactHex)
    }
}

public struct RSSIExport: Codable, Hashable, Sendable {
    public struct Sample: Codable, Hashable, Sendable {
        public let timestamp: Date
        public let dBm: Int
    }

    public let samples: [Sample]
    public let average: Double?
    public let minimum: Int?
    public let maximum: Int?
    public let trend: String
    public let note: String

    public init(_ history: RSSIHistory) {
        let samples = history.samples
        let stats = RSSIHistory.statistics(for: samples)
        self.samples = samples.map { Sample(timestamp: $0.timestamp, dBm: $0.value) }
        average = stats.average
        minimum = stats.minimum
        maximum = stats.maximum
        trend = stats.trend.rawValue
        note = "RSSI is a relative signal-strength reading and is not a reliable distance measurement."
    }
}

public struct ClassicExport: Codable, Hashable, Sendable {
    public struct CoD: Codable, Hashable, Sendable {
        public let raw: String
        public let major: String
        public let minor: String
        public let serviceClasses: [String]
    }

    public struct Attribute: Codable, Hashable, Sendable {
        public let id: String
        public let name: String
        public let value: SDPDataElement
    }

    public struct Record: Codable, Hashable, Sendable {
        public let title: String
        public let serviceClasses: [UUIDExport]
        public let rfcommChannel: UInt8?
        public let l2capPSM: UInt16?
        public let profiles: [String]
        public let attributes: [Attribute]
    }

    public let address: String
    public let oui: String
    public let name: String?
    public let classOfDevice: CoD?
    public let paired: Bool
    public let connected: Bool
    public let favorite: Bool
    public let rssi: Int?
    public let pnp: [String: String]?
    public let lastInquiryUpdate: Date?
    public let lastServicesUpdate: Date?
    public let serviceRecords: [Record]

    public init(_ info: ClassicDeviceInfo) {
        address = info.address
        oui = info.oui
        name = info.name
        classOfDevice = info.classOfDevice.map {
            CoD(raw: $0.hexString, major: $0.majorName, minor: $0.minorName, serviceClasses: $0.serviceClasses)
        }
        paired = info.isPaired
        connected = info.isConnected
        favorite = info.isFavorite
        rssi = info.rssi
        pnp = info.pnpInformation.map { Dictionary($0.fields.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first }) }
        lastInquiryUpdate = info.lastInquiryUpdate
        lastServicesUpdate = info.lastServicesUpdate
        serviceRecords = info.serviceRecords.map { record in
            Record(
                title: record.title,
                serviceClasses: record.serviceClassIDs.map(UUIDExport.init),
                rfcommChannel: record.rfcommChannel,
                l2capPSM: record.l2capPSM,
                profiles: record.profiles.map { "\($0.uuid.displayName) v\($0.version)" },
                attributes: record.attributes.map {
                    Attribute(id: String(format: "0x%04X", $0.id), name: $0.name(inPnPRecord: record.isPnPInformation), value: $0.value)
                }
            )
        }
    }
}

/// Export for one device. Matches the structure
/// `{ device, advertisement, services, characteristics, events }` plus extras.
public struct DeviceExport: Codable, Hashable, Sendable {
    public var schemaVersion = ExportSchema.version
    public var exportedAt: Date
    public var generator: ExportGenerator
    public var device: DeviceSummaryExport
    public var advertisement: AdvertisementExport?
    public var services: [ServiceExport]
    public var characteristics: [CharacteristicExport]
    public var values: [ValueRecordExport]
    public var rssi: RSSIExport
    public var classic: ClassicExport?
    public var events: [EventExport]
}

/// Export for the whole session.
public struct SessionExport: Codable, Hashable, Sendable {
    public var schemaVersion = ExportSchema.version
    public var exportedAt: Date
    public var generator: ExportGenerator
    public var diagnostics: [String: String]
    public var devices: [DeviceExport]
    public var events: [EventExport]
}

public enum ExportCoding {
    /// Pretty, key-sorted JSON with millisecond ISO-8601 timestamps
    /// (notifications often arrive within the same second).
    public static func jsonEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date))
        }
        return encoder
    }

    public static func jsonDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) { return date }
            if let date = try? Date.ISO8601FormatStyle().parse(text) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date \(text)")
        }
        return decoder
    }
}
