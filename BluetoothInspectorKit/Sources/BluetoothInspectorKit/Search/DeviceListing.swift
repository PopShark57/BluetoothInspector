import Foundation

/// Flattened, immutable row for the device table. Built from the live device
/// models on a throttle so sorting/filtering never runs per advertisement.
public struct DeviceListItem: Identifiable, Hashable, Sendable {
    public let id: DeviceID
    public let name: String?
    public let displayName: String
    public let transport: BluetoothTransport
    public let dualModeHint: DualModeHint
    public let rssi: Int?
    public let connectionState: ConnectionState
    public let manufacturer: String?
    public let lastSeen: Date?
    public let isConnectable: Bool?
    public let isPaired: Bool?
    public let isFavorite: Bool
    public let isSaved: Bool
    public let isSystemConnected: Bool
    /// False for saved devices that have not been seen in this session.
    public let isLive: Bool
    public let serviceUUIDs: [BluetoothUUID]
    /// Extra text matched by search (GATT UUIDs and names, notes…).
    public let searchText: String

    public init(
        id: DeviceID,
        name: String?,
        displayName: String? = nil,
        transport: BluetoothTransport,
        dualModeHint: DualModeHint = .none,
        rssi: Int?,
        connectionState: ConnectionState = .disconnected,
        manufacturer: String? = nil,
        lastSeen: Date?,
        isConnectable: Bool? = nil,
        isPaired: Bool? = nil,
        isFavorite: Bool = false,
        isSaved: Bool = false,
        isSystemConnected: Bool = false,
        isLive: Bool = true,
        serviceUUIDs: [BluetoothUUID] = [],
        searchText: String = ""
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName ?? name ?? "Unnamed"
        self.transport = transport
        self.dualModeHint = dualModeHint
        self.rssi = rssi
        self.connectionState = connectionState
        self.manufacturer = manufacturer
        self.lastSeen = lastSeen
        self.isConnectable = isConnectable
        self.isPaired = isPaired
        self.isFavorite = isFavorite
        self.isSaved = isSaved
        self.isSystemConnected = isSystemConnected
        self.isLive = isLive
        self.serviceUUIDs = serviceUUIDs
        self.searchText = searchText
    }

    public var hasName: Bool { !(name?.isEmpty ?? true) }
    public var identifierString: String { id.identifierString }
    /// Sort key that puts missing RSSI last when sorting strongest-first.
    public var rssiSortValue: Int { rssi ?? -1000 }
    public var nameSortValue: String { displayName.lowercased() }
    public var lastSeenSortValue: Date { lastSeen ?? .distantPast }
}

public enum DeviceSortKey: String, CaseIterable, Identifiable, Codable, Sendable {
    case rssi
    case name
    case lastSeen
    case identifier

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .rssi: "Signal Strength"
        case .name: "Name"
        case .lastSeen: "Last Seen"
        case .identifier: "Identifier"
        }
    }
}

public struct DeviceSort: Hashable, Codable, Sendable {
    public var key: DeviceSortKey
    public var ascending: Bool

    public init(key: DeviceSortKey = .rssi, ascending: Bool = false) {
        self.key = key
        self.ascending = ascending
    }

    public func apply(_ items: [DeviceListItem]) -> [DeviceListItem] {
        items.sorted { lhs, rhs in
            let ordered: Bool
            switch key {
            case .rssi:
                if lhs.rssiSortValue == rhs.rssiSortValue { return lhs.identifierString < rhs.identifierString }
                ordered = lhs.rssiSortValue < rhs.rssiSortValue
            case .name:
                if lhs.nameSortValue == rhs.nameSortValue { return lhs.identifierString < rhs.identifierString }
                ordered = lhs.nameSortValue < rhs.nameSortValue
            case .lastSeen:
                if lhs.lastSeenSortValue == rhs.lastSeenSortValue { return lhs.identifierString < rhs.identifierString }
                ordered = lhs.lastSeenSortValue < rhs.lastSeenSortValue
            case .identifier:
                ordered = lhs.identifierString < rhs.identifierString
            }
            return ascending ? ordered : !ordered
        }
    }
}

public enum TransportFilter: String, CaseIterable, Identifiable, Codable, Sendable {
    case all
    case lowEnergy
    case classic
    case possibleDualMode

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: "All"
        case .lowEnergy: "BLE"
        case .classic: "Classic"
        case .possibleDualMode: "Dual-mode?"
        }
    }
}

public enum NameFilter: String, CaseIterable, Identifiable, Codable, Sendable {
    case any
    case named
    case unnamed

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .any: "Any Name"
        case .named: "Named Only"
        case .unnamed: "Unnamed Only"
        }
    }
}

public struct DeviceFilter: Hashable, Codable, Sendable {
    public var transport: TransportFilter
    public var name: NameFilter
    /// Hide devices whose last RSSI is below this (dBm). Devices without an
    /// RSSI (e.g. paired Classic devices out of range) are kept.
    public var minimumRSSI: Int?
    /// Service UUID text; matches advertised services by short or full UUID or SIG name.
    public var serviceUUID: String
    public var searchText: String
    public var favoritesOnly: Bool

    public init(transport: TransportFilter = .all, name: NameFilter = .any, minimumRSSI: Int? = nil,
                serviceUUID: String = "", searchText: String = "", favoritesOnly: Bool = false) {
        self.transport = transport
        self.name = name
        self.minimumRSSI = minimumRSSI
        self.serviceUUID = serviceUUID
        self.searchText = searchText
        self.favoritesOnly = favoritesOnly
    }

    public var isActive: Bool {
        transport != .all || name != .any || minimumRSSI != nil || !serviceUUID.isEmpty || favoritesOnly
    }

    public func matches(_ item: DeviceListItem) -> Bool {
        switch transport {
        case .all: break
        case .lowEnergy: guard item.transport == .lowEnergy else { return false }
        case .classic: guard item.transport == .classic else { return false }
        case .possibleDualMode: guard item.dualModeHint != .none else { return false }
        }
        switch name {
        case .any: break
        case .named: guard item.hasName else { return false }
        case .unnamed: guard !item.hasName else { return false }
        }
        if favoritesOnly, !item.isFavorite { return false }
        if let minimumRSSI, let rssi = item.rssi, rssi < minimumRSSI { return false }
        let serviceQuery = serviceUUID.trimmingCharacters(in: .whitespaces)
        if !serviceQuery.isEmpty {
            let wanted = BluetoothUUID(string: serviceQuery)
            let matched = item.serviceUUIDs.contains { uuid in
                if let wanted, uuid == wanted { return true }
                return SearchMatcher(serviceQuery).matches(any: [uuid.uuidString, uuid.shortString, uuid.sigName ?? ""])
            }
            guard matched else { return false }
        }
        let matcher = SearchMatcher(searchText)
        if !matcher.isEmpty {
            let fields = [item.displayName, item.name ?? "", item.identifierString, item.manufacturer ?? "",
                          item.transport.title, item.searchText]
                + item.serviceUUIDs.flatMap { [$0.shortString, $0.uuidString, $0.sigName ?? ""] }
            guard matcher.matches(any: fields) else { return false }
        }
        return true
    }

    public func apply(_ items: [DeviceListItem], sort: DeviceSort) -> [DeviceListItem] {
        sort.apply(items.filter(matches))
    }
}
