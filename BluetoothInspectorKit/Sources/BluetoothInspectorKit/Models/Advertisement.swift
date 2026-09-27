import Foundation

/// Advertisement content as CoreBluetooth delivers it.
///
/// CoreBluetooth parses the advertising PDU for us and only hands over the
/// fields listed here (`CBAdvertisementData*Key`). The raw PDU, the AD Flags
/// field, the advertiser address and its type, advertising interval, PHY and
/// channel are *not* available to apps on macOS, so they are not modelled.
public struct AdvertisementData: Hashable, Codable, Sendable {
    public var localName: String?
    public var serviceUUIDs: [BluetoothUUID]
    public var overflowServiceUUIDs: [BluetoothUUID]
    public var solicitedServiceUUIDs: [BluetoothUUID]
    public var manufacturerData: Data?
    public var serviceData: [ServiceDataEntry]
    public var txPowerLevel: Int?
    public var isConnectable: Bool?

    public init(
        localName: String? = nil,
        serviceUUIDs: [BluetoothUUID] = [],
        overflowServiceUUIDs: [BluetoothUUID] = [],
        solicitedServiceUUIDs: [BluetoothUUID] = [],
        manufacturerData: Data? = nil,
        serviceData: [ServiceDataEntry] = [],
        txPowerLevel: Int? = nil,
        isConnectable: Bool? = nil
    ) {
        self.localName = localName
        self.serviceUUIDs = serviceUUIDs
        self.overflowServiceUUIDs = overflowServiceUUIDs
        self.solicitedServiceUUIDs = solicitedServiceUUIDs
        self.manufacturerData = manufacturerData
        self.serviceData = serviceData.sorted { $0.uuid < $1.uuid }
        self.txPowerLevel = txPowerLevel
        self.isConnectable = isConnectable
    }

    public var isEmpty: Bool {
        localName == nil && serviceUUIDs.isEmpty && overflowServiceUUIDs.isEmpty
            && solicitedServiceUUIDs.isEmpty && manufacturerData == nil && serviceData.isEmpty
            && txPowerLevel == nil && isConnectable == nil
    }

    /// Advertising and scan-response packets arrive as separate callbacks, and
    /// a scan response typically carries only some fields (often just the
    /// name). Merging keeps the most recent value of every field seen, which
    /// is what a developer expects the device "is advertising".
    public func merging(_ newer: AdvertisementData) -> AdvertisementData {
        AdvertisementData(
            localName: newer.localName ?? localName,
            serviceUUIDs: newer.serviceUUIDs.isEmpty ? serviceUUIDs : newer.serviceUUIDs,
            overflowServiceUUIDs: newer.overflowServiceUUIDs.isEmpty ? overflowServiceUUIDs : newer.overflowServiceUUIDs,
            solicitedServiceUUIDs: newer.solicitedServiceUUIDs.isEmpty ? solicitedServiceUUIDs : newer.solicitedServiceUUIDs,
            manufacturerData: newer.manufacturerData ?? manufacturerData,
            serviceData: Self.merge(serviceData, newer.serviceData),
            txPowerLevel: newer.txPowerLevel ?? txPowerLevel,
            isConnectable: newer.isConnectable ?? isConnectable
        )
    }

    private static func merge(_ old: [ServiceDataEntry], _ new: [ServiceDataEntry]) -> [ServiceDataEntry] {
        var byUUID = Dictionary(old.map { ($0.uuid, $0) }, uniquingKeysWith: { _, last in last })
        for entry in new { byUUID[entry.uuid] = entry }
        return byUUID.values.sorted { $0.uuid < $1.uuid }
    }

    /// Every service UUID the advertisement mentions, for filtering and search.
    public var allServiceUUIDs: [BluetoothUUID] {
        serviceUUIDs + overflowServiceUUIDs + solicitedServiceUUIDs + serviceData.map(\.uuid)
    }

    public var manufacturer: ManufacturerData? {
        manufacturerData.flatMap(ManufacturerData.init(data:))
    }
}

public struct ServiceDataEntry: Hashable, Codable, Sendable {
    public let uuid: BluetoothUUID
    public let data: Data

    public init(uuid: BluetoothUUID, data: Data) {
        self.uuid = uuid
        self.data = data
    }
}

/// A single raw advertisement callback, as recorded in a device's history.
public struct AdvertisementPacket: Hashable, Codable, Sendable {
    public let timestamp: Date
    public let rssi: Int?
    public let advertisement: AdvertisementData

    public init(timestamp: Date, rssi: Int?, advertisement: AdvertisementData) {
        self.timestamp = timestamp
        self.rssi = rssi
        self.advertisement = advertisement
    }
}

/// One row of the structured advertisement table.
public struct AdvertisementField: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let value: String
    public let rawHex: String

    public init(id: String, name: String, value: String, rawHex: String = "") {
        self.id = id
        self.name = name
        self.value = value
        self.rawHex = rawHex
    }
}

public extension AdvertisementData {
    /// Structured rows: field name, decoded value, and raw hex where bytes exist.
    var fields: [AdvertisementField] {
        var rows: [AdvertisementField] = []
        if let localName {
            rows.append(.init(id: "name", name: "Local Name", value: localName, rawHex: Data(localName.utf8).hexString))
        }
        if let isConnectable {
            rows.append(.init(id: "connectable", name: "Connectable", value: isConnectable ? "Yes" : "No"))
        }
        if let txPowerLevel {
            rows.append(.init(id: "tx", name: "TX Power Level", value: "\(txPowerLevel) dBm",
                              rawHex: String(format: "%02X", UInt8(bitPattern: Int8(clamping: txPowerLevel)))))
        }
        for (index, uuid) in serviceUUIDs.enumerated() {
            rows.append(.init(id: "svc-\(index)", name: "Service UUID", value: uuid.displayName, rawHex: uuid.uuidString))
        }
        for (index, uuid) in overflowServiceUUIDs.enumerated() {
            rows.append(.init(id: "ovf-\(index)", name: "Overflow Service UUID", value: uuid.displayName, rawHex: uuid.uuidString))
        }
        for (index, uuid) in solicitedServiceUUIDs.enumerated() {
            rows.append(.init(id: "sol-\(index)", name: "Solicited Service UUID", value: uuid.displayName, rawHex: uuid.uuidString))
        }
        if let manufacturerData {
            let decoded = ManufacturerData(data: manufacturerData)
            rows.append(.init(id: "mfr", name: "Manufacturer Data",
                              value: decoded?.summary ?? "\(manufacturerData.count) bytes (too short for a company ID)",
                              rawHex: manufacturerData.hexString))
            if let decoded {
                for (index, field) in decoded.fields.enumerated() {
                    rows.append(.init(id: "mfr-\(index)", name: "  \(field.name)", value: field.value))
                }
            }
        }
        for entry in serviceData {
            let decoded = ServiceDataDecoder.decode(uuid: entry.uuid, data: entry.data)
            rows.append(.init(id: "sd-\(entry.uuid.uuidString)", name: "Service Data (\(entry.uuid.displayName))",
                              value: decoded?.summary ?? "\(entry.data.count) bytes", rawHex: entry.data.hexString))
            for (index, field) in (decoded?.fields ?? []).enumerated() {
                rows.append(.init(id: "sd-\(entry.uuid.uuidString)-\(index)", name: "  \(field.name)", value: field.value))
            }
        }
        return rows
    }
}
