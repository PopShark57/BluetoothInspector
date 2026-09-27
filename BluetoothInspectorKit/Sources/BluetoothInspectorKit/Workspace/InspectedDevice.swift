import Foundation
import Observation

/// A characteristic value observed on a device: a read response, a
/// notification/indication, or a value this app wrote.
public struct ValueRecord: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case read
        case notification
        case write

        public var title: String {
            switch self {
            case .read: "Read"
            case .notification: "Notify/Indicate"
            case .write: "Write"
            }
        }
    }

    public let id: UInt64
    public let timestamp: Date
    public let kind: Kind
    public let characteristicID: GATTNodeID
    public let characteristicUUID: BluetoothUUID
    public let data: Data
    public let decodedSummary: String?

    public init(id: UInt64, timestamp: Date, kind: Kind, characteristicID: GATTNodeID,
                characteristicUUID: BluetoothUUID, data: Data, decodedSummary: String?) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.characteristicID = characteristicID
        self.characteristicUUID = characteristicUUID
        self.data = data
        self.decodedSummary = decodedSummary
    }
}

/// Live state of one device (BLE peripheral or Classic device).
///
/// Each property is observed independently, so a view that shows only the
/// GATT tree is not re-rendered by the RSSI updates that arrive with every
/// advertisement.
@MainActor
@Observable
public final class InspectedDevice: Identifiable {
    public static let valueHistoryCapacity = 5_000
    public static let packetHistoryCapacity = 500

    public nonisolated let id: DeviceID
    public let firstSeen: Date

    /// Name from the system (CoreBluetooth `peripheral.name` / IOBluetooth `name`).
    public var systemName: String?
    public var advertisement = AdvertisementData()
    public var advertisementPacketCount = 0
    public var advertisementChangeCount = 0
    public var lastAdvertisementChange: Date?

    public var rssi: Int?
    public var lastSeen: Date?

    // High-rate histories are not observed directly: they change with every
    // advertisement or notification. Views observe `historyRevision`, which
    // the workspace bumps at most once per UI tick.
    @ObservationIgnored public private(set) var rssiHistory = RSSIHistory()
    @ObservationIgnored public private(set) var recentPackets = RingBuffer<AdvertisementPacket>(capacity: InspectedDevice.packetHistoryCapacity)
    @ObservationIgnored public private(set) var valueHistory = RingBuffer<ValueRecord>(capacity: InspectedDevice.valueHistoryCapacity)
    @ObservationIgnored private var historyDirty = false
    /// Changes whenever any history above changed since the last UI tick.
    public private(set) var historyRevision = 0

    public var connectionState: ConnectionState = .disconnected
    /// Connected to the Mac by the system or another app (not by us).
    public var isSystemConnected = false
    public var connectedAt: Date?
    public var maximumWriteLength: Int?
    public var maximumWriteWithoutResponseLength: Int?
    public var gatt = GATTTree()
    public var lastError: String?

    public var classic: ClassicDeviceInfo?
    public var isSDPQueryRunning = false
    public var dualModeHint: DualModeHint = .none

    public init(id: DeviceID, firstSeen: Date) {
        self.id = id
        self.firstSeen = firstSeen
    }

    public var transport: BluetoothTransport { id.transport }

    /// Advertised name wins over the system's cached GAP name because it is
    /// what the device is broadcasting right now.
    public var name: String? {
        if let local = advertisement.localName, !local.isEmpty { return local }
        if let systemName, !systemName.isEmpty { return systemName }
        return classic?.name
    }

    public var displayName: String { name ?? "Unnamed" }

    public var isConnected: Bool {
        connectionState == .connected || (classic?.isConnected ?? false)
    }

    /// Best manufacturer information available: GATT Manufacturer Name or
    /// PnP ID when read, then advertisement company ID, then Classic PnP record.
    public var manufacturer: String? {
        for characteristic in gatt.allCharacteristics {
            guard let value = characteristic.value else { continue }
            if characteristic.uuid == BluetoothUUID(uint16: 0x2A29), let text = ByteFormatter.utf8(value), !text.isEmpty {
                return text.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            }
        }
        if let company = advertisement.manufacturer {
            return company.companyName ?? String(format: "Company 0x%04X", company.companyID)
        }
        return classic?.pnpInformation?.vendorName
    }

    public var isPaired: Bool? { classic?.isPaired }

    /// Every service UUID we know about from advertisements, GATT or SDP.
    public var knownServiceUUIDs: [BluetoothUUID] {
        var set = Set(advertisement.allServiceUUIDs)
        set.formUnion(gatt.services.map(\.uuid))
        set.formUnion(classic?.serviceRecords.flatMap(\.serviceClassIDs) ?? [])
        return set.sorted()
    }

    public var valueRecords: [ValueRecord] { valueHistory.elements }
    public var packets: [AdvertisementPacket] { recentPackets.elements }

    func appendPacket(_ packet: AdvertisementPacket) {
        recentPackets.append(packet)
        historyDirty = true
    }

    func appendValue(_ record: ValueRecord) {
        valueHistory.append(record)
        historyDirty = true
    }

    /// Records a valid RSSI reading (updating `rssi`); returns false for 127/out-of-range.
    @discardableResult
    func recordRSSI(_ value: Int, at date: Date) -> Bool {
        guard rssiHistory.record(value, at: date) else { return false }
        rssi = value
        historyDirty = true
        return true
    }

    /// Publishes history changes to observers. Returns true if anything changed.
    @discardableResult
    public func publishHistory() -> Bool {
        guard historyDirty else { return false }
        historyDirty = false
        historyRevision &+= 1
        return true
    }

    public func clearValueHistory() {
        valueHistory.removeAll()
        historyDirty = true
        publishHistory()
    }

    public func clearRSSIHistory() {
        rssiHistory.clear()
        historyDirty = true
        publishHistory()
    }

    /// Characteristic + descriptor UUIDs/names for search.
    var searchText: String {
        var parts: [String] = [id.identifierString]
        for service in gatt.services {
            parts += [service.uuid.shortString, service.name]
            for characteristic in service.characteristics {
                parts += [characteristic.uuid.shortString, characteristic.uuid.uuidString, characteristic.name]
            }
        }
        if let classic {
            parts += classic.profileNames
            if let cod = classic.classOfDevice { parts.append(cod.summary) }
        }
        return parts.joined(separator: " ")
    }
}
