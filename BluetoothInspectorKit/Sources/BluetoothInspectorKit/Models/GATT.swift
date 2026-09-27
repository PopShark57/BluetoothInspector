import Foundation

/// Opaque identity for one discovered GATT attribute (service, characteristic
/// or descriptor).
///
/// CoreBluetooth does not expose ATT handles, and a peripheral may contain the
/// same UUID more than once, so the BLE adapter mints one of these for each
/// CoreBluetooth object it sees and keeps the mapping privately.
public struct GATTNodeID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString }
}

/// Characteristic properties; raw values match `CBCharacteristicProperties`.
public struct GATTProperties: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: UInt

    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    public static let broadcast = GATTProperties(rawValue: 0x01)
    public static let read = GATTProperties(rawValue: 0x02)
    public static let writeWithoutResponse = GATTProperties(rawValue: 0x04)
    public static let write = GATTProperties(rawValue: 0x08)
    public static let notify = GATTProperties(rawValue: 0x10)
    public static let indicate = GATTProperties(rawValue: 0x20)
    public static let authenticatedSignedWrites = GATTProperties(rawValue: 0x40)
    public static let extendedProperties = GATTProperties(rawValue: 0x80)
    /// Apple extensions: only reported for local (peripheral-role) attributes.
    public static let notifyEncryptionRequired = GATTProperties(rawValue: 0x100)
    public static let indicateEncryptionRequired = GATTProperties(rawValue: 0x200)

    public struct Descriptor: Hashable, Sendable {
        public let property: GATTProperties
        public let title: String
        public let shortTitle: String
        public let symbolName: String
    }

    public static let all: [Descriptor] = [
        .init(property: .read, title: "Read", shortTitle: "R", symbolName: "arrow.down.doc"),
        .init(property: .write, title: "Write", shortTitle: "W", symbolName: "square.and.pencil"),
        .init(property: .writeWithoutResponse, title: "Write Without Response", shortTitle: "WNR", symbolName: "paperplane"),
        .init(property: .notify, title: "Notify", shortTitle: "N", symbolName: "bell"),
        .init(property: .indicate, title: "Indicate", shortTitle: "I", symbolName: "bell.badge"),
        .init(property: .broadcast, title: "Broadcast", shortTitle: "B", symbolName: "dot.radiowaves.left.and.right"),
        .init(property: .authenticatedSignedWrites, title: "Authenticated Signed Writes", shortTitle: "ASW", symbolName: "signature"),
        .init(property: .extendedProperties, title: "Extended Properties", shortTitle: "EXT", symbolName: "ellipsis.circle"),
        .init(property: .notifyEncryptionRequired, title: "Notify (Encryption Required)", shortTitle: "NE", symbolName: "lock"),
        .init(property: .indicateEncryptionRequired, title: "Indicate (Encryption Required)", shortTitle: "IE", symbolName: "lock"),
    ]

    public var descriptors: [Descriptor] { Self.all.filter { contains($0.property) } }
    public var titles: [String] { descriptors.map(\.title) }

    public var isReadable: Bool { contains(.read) }
    public var isWritable: Bool { contains(.write) || contains(.writeWithoutResponse) }
    public var canSubscribe: Bool { contains(.notify) || contains(.indicate) }
}

public enum WriteType: String, Codable, Sendable, CaseIterable, Identifiable {
    case withResponse
    case withoutResponse

    public var id: String { rawValue }
    public var title: String { self == .withResponse ? "With Response" : "Without Response" }
}

public enum DiscoveryState: String, Codable, Sendable {
    case notStarted
    case discovering
    case complete
    case failed
}

/// A descriptor value as CoreBluetooth reports it. CoreBluetooth converts
/// several descriptors to Foundation types (NSNumber for 0x2900/0x2902/0x2903,
/// NSString for 0x2901) and leaves the rest as NSData; the BLE adapter
/// normalizes all of them back to bytes plus a display string.
public struct DescriptorValue: Hashable, Codable, Sendable {
    public let data: Data
    public let displayText: String

    public init(data: Data, displayText: String) {
        self.data = data
        self.displayText = displayText
    }
}

public struct GATTDescriptor: Identifiable, Hashable, Codable, Sendable {
    public let id: GATTNodeID
    public let uuid: BluetoothUUID
    public var value: DescriptorValue?
    public var lastError: String?

    public init(id: GATTNodeID, uuid: BluetoothUUID, value: DescriptorValue? = nil) {
        self.id = id
        self.uuid = uuid
        self.value = value
    }

    public var name: String { AssignedNumbers.descriptorName(uuid) ?? "Descriptor" }
}

public struct GATTCharacteristic: Identifiable, Hashable, Codable, Sendable {
    public let id: GATTNodeID
    public let serviceID: GATTNodeID
    public let uuid: BluetoothUUID
    public var properties: GATTProperties
    public var value: Data?
    public var valueUpdatedAt: Date?
    public var isNotifying: Bool
    public var descriptors: [GATTDescriptor]
    public var descriptorDiscovery: DiscoveryState
    public var lastError: String?
    /// Maximum single write sizes CoreBluetooth reports for this connection.
    public var maximumWriteLength: Int?
    public var maximumWriteWithoutResponseLength: Int?

    public init(
        id: GATTNodeID,
        serviceID: GATTNodeID,
        uuid: BluetoothUUID,
        properties: GATTProperties,
        value: Data? = nil,
        isNotifying: Bool = false,
        descriptors: [GATTDescriptor] = []
    ) {
        self.id = id
        self.serviceID = serviceID
        self.uuid = uuid
        self.properties = properties
        self.value = value
        self.isNotifying = isNotifying
        self.descriptors = descriptors
        self.descriptorDiscovery = .notStarted
    }

    public var name: String { AssignedNumbers.characteristicName(uuid) ?? "Characteristic" }

    public var presentationFormat: PresentationFormat? {
        descriptors.first { $0.uuid == BluetoothUUID(uint16: 0x2904) }?.value.flatMap { PresentationFormat(data: $0.data) }
    }

    public var userDescription: String? {
        descriptors.first { $0.uuid == BluetoothUUID(uint16: 0x2901) }?.value?.displayText
    }
}

public struct GATTService: Identifiable, Hashable, Codable, Sendable {
    public let id: GATTNodeID
    public let uuid: BluetoothUUID
    public let isPrimary: Bool
    public var characteristics: [GATTCharacteristic]
    public var includedServiceIDs: [GATTNodeID]
    public var characteristicDiscovery: DiscoveryState
    public var lastError: String?

    public init(id: GATTNodeID, uuid: BluetoothUUID, isPrimary: Bool, characteristics: [GATTCharacteristic] = [], includedServiceIDs: [GATTNodeID] = []) {
        self.id = id
        self.uuid = uuid
        self.isPrimary = isPrimary
        self.characteristics = characteristics
        self.includedServiceIDs = includedServiceIDs
        self.characteristicDiscovery = .notStarted
    }

    public var name: String { AssignedNumbers.serviceName(uuid) ?? (isPrimary ? "Primary Service" : "Secondary Service") }
}

/// The discovered attribute hierarchy of one peripheral.
///
/// Lookup tables are kept alongside the ordered arrays so notification bursts
/// (hundreds per second from some sensors) update values in O(1).
public struct GATTTree: Hashable, Codable, Sendable {
    public private(set) var services: [GATTService] = []
    public var serviceDiscovery: DiscoveryState = .notStarted
    public var lastError: String?

    private var serviceIndex: [GATTNodeID: Int] = [:]
    private var characteristicIndex: [GATTNodeID: CharacteristicLocation] = [:]

    private struct CharacteristicLocation: Hashable, Codable, Sendable {
        let service: Int
        let characteristic: Int
    }

    public init() {}

    public var isEmpty: Bool { services.isEmpty }
    public var characteristicCount: Int { characteristicIndex.count }
    public var allCharacteristics: [GATTCharacteristic] { services.flatMap(\.characteristics) }

    /// Replaces or appends services, preserving already-discovered children of
    /// services that are re-reported (CoreBluetooth re-delivers the full list
    /// after `didModifyServices`).
    public mutating func upsert(services newServices: [GATTService]) {
        for service in newServices {
            if let index = serviceIndex[service.id] {
                var merged = service
                merged.characteristics = services[index].characteristics
                merged.characteristicDiscovery = services[index].characteristicDiscovery
                services[index] = merged
            } else {
                services.append(service)
            }
        }
        rebuildIndex()
    }

    /// Removes services CoreBluetooth reports as invalidated.
    public mutating func remove(serviceIDs: Set<GATTNodeID>) {
        services.removeAll { serviceIDs.contains($0.id) }
        rebuildIndex()
    }

    public mutating func setIncludedServices(_ included: [GATTNodeID], for serviceID: GATTNodeID) {
        guard let index = serviceIndex[serviceID] else { return }
        services[index].includedServiceIDs = included
    }

    public mutating func setCharacteristics(_ characteristics: [GATTCharacteristic], for serviceID: GATTNodeID) {
        guard let index = serviceIndex[serviceID] else { return }
        let previous = Dictionary(services[index].characteristics.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        services[index].characteristics = characteristics.map { incoming in
            guard let old = previous[incoming.id] else { return incoming }
            var merged = incoming
            merged.value = old.value
            merged.valueUpdatedAt = old.valueUpdatedAt
            merged.descriptors = old.descriptors
            merged.descriptorDiscovery = old.descriptorDiscovery
            return merged
        }
        services[index].characteristicDiscovery = .complete
        rebuildIndex()
    }

    public mutating func setServiceState(_ state: DiscoveryState, error: String? = nil, for serviceID: GATTNodeID) {
        guard let index = serviceIndex[serviceID] else { return }
        services[index].characteristicDiscovery = state
        services[index].lastError = error
    }

    public mutating func setDescriptors(_ descriptors: [GATTDescriptor], for characteristicID: GATTNodeID) {
        mutateCharacteristic(characteristicID) { characteristic in
            let previous = Dictionary(characteristic.descriptors.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            characteristic.descriptors = descriptors.map { previous[$0.id] ?? $0 }
            characteristic.descriptorDiscovery = .complete
        }
    }

    public mutating func setDescriptorValue(_ value: DescriptorValue?, error: String?, descriptorID: GATTNodeID, characteristicID: GATTNodeID) {
        mutateCharacteristic(characteristicID) { characteristic in
            guard let index = characteristic.descriptors.firstIndex(where: { $0.id == descriptorID }) else { return }
            if let value { characteristic.descriptors[index].value = value }
            characteristic.descriptors[index].lastError = error
        }
    }

    public mutating func updateValue(_ value: Data, at date: Date, for characteristicID: GATTNodeID) {
        mutateCharacteristic(characteristicID) {
            $0.value = value
            $0.valueUpdatedAt = date
            $0.lastError = nil
        }
    }

    public mutating func setNotifying(_ isNotifying: Bool, for characteristicID: GATTNodeID) {
        mutateCharacteristic(characteristicID) { $0.isNotifying = isNotifying }
    }

    public mutating func setError(_ error: String?, for characteristicID: GATTNodeID) {
        mutateCharacteristic(characteristicID) { $0.lastError = error }
    }

    public mutating func setWriteLimits(withResponse: Int, withoutResponse: Int) {
        for serviceIndex in services.indices {
            for characteristicIndex in services[serviceIndex].characteristics.indices {
                services[serviceIndex].characteristics[characteristicIndex].maximumWriteLength = withResponse
                services[serviceIndex].characteristics[characteristicIndex].maximumWriteWithoutResponseLength = withoutResponse
            }
        }
    }

    /// Marks every characteristic as no longer notifying (after a disconnect
    /// the peripheral forgets unbonded subscriptions).
    public mutating func clearNotifications() {
        for serviceIndex in services.indices {
            for characteristicIndex in services[serviceIndex].characteristics.indices {
                services[serviceIndex].characteristics[characteristicIndex].isNotifying = false
            }
        }
    }

    public func service(_ id: GATTNodeID) -> GATTService? {
        serviceIndex[id].map { services[$0] }
    }

    public func characteristic(_ id: GATTNodeID) -> GATTCharacteristic? {
        characteristicIndex[id].map { services[$0.service].characteristics[$0.characteristic] }
    }

    public func descriptor(_ id: GATTNodeID) -> (GATTCharacteristic, GATTDescriptor)? {
        for service in services {
            for characteristic in service.characteristics {
                if let descriptor = characteristic.descriptors.first(where: { $0.id == id }) {
                    return (characteristic, descriptor)
                }
            }
        }
        return nil
    }

    public var primaryServices: [GATTService] { services.filter(\.isPrimary) }
    public var secondaryServices: [GATTService] { services.filter { !$0.isPrimary } }

    private mutating func mutateCharacteristic(_ id: GATTNodeID, _ body: (inout GATTCharacteristic) -> Void) {
        guard let location = characteristicIndex[id] else { return }
        body(&services[location.service].characteristics[location.characteristic])
    }

    private mutating func rebuildIndex() {
        serviceIndex = [:]
        characteristicIndex = [:]
        for (serviceOffset, service) in services.enumerated() {
            serviceIndex[service.id] = serviceOffset
            for (characteristicOffset, characteristic) in service.characteristics.enumerated() {
                characteristicIndex[characteristic.id] = CharacteristicLocation(service: serviceOffset, characteristic: characteristicOffset)
            }
        }
    }
}
