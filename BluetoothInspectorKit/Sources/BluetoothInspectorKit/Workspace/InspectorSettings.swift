import Foundation

/// Which devices are remembered in Saved Devices.
public enum HistoryMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case off
    case connectedAndFavorites
    case everything

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: "Don’t Remember Devices"
        case .connectedAndFavorites: "Connected, Paired & Favorites"
        case .everything: "Every Device Seen"
        }
    }
}

/// User preferences that change workspace behavior. Persisted by the app.
public struct InspectorSettings: Hashable, Codable, Sendable {
    public var allowDuplicates = true
    /// Comma-separated service UUIDs for the hardware scan filter.
    public var scanServiceFilter = ""
    public var connectionTimeout: TimeInterval = 15
    /// Read descriptors after discovery (read-only; can trigger pairing on encrypted descriptors).
    public var autoReadDescriptors = true
    /// Read every readable characteristic after discovery. Off by default
    /// because reading an encrypted characteristic makes macOS show a pairing prompt.
    public var autoReadCharacteristics = false
    /// Ask for confirmation before any write is sent.
    public var confirmWrites = true
    /// Seconds between RSSI reads for connected peripherals; 0 disables polling.
    public var rssiPollInterval: TimeInterval = 1
    public var logCapacity = EventLog.defaultCapacity
    public var logAdvertisementChanges = true
    public var logRSSIReadings = false
    public var historyMode = HistoryMode.connectedAndFavorites
    public var classicInquiryDuration: TimeInterval = 10
    /// Services used to ask the system for peripherals it is already connected to.
    public var systemConnectedServiceUUIDs = "180A, 180F, 1812, 1800, 1801"

    public init() {}

    public var scanOptions: ScanOptions {
        ScanOptions(allowDuplicates: allowDuplicates, serviceUUIDs: Self.parseUUIDList(scanServiceFilter))
    }

    public var systemConnectedServices: [BluetoothUUID] {
        Self.parseUUIDList(systemConnectedServiceUUIDs)
    }

    public static func parseUUIDList(_ text: String) -> [BluetoothUUID] {
        text.split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .compactMap { BluetoothUUID(string: String($0)) }
    }

    // Decode leniently so adding a setting never resets a user's preferences.
    public init(from decoder: Decoder) throws {
        let defaults = InspectorSettings()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        allowDuplicates = try container.decodeIfPresent(Bool.self, forKey: .allowDuplicates) ?? defaults.allowDuplicates
        scanServiceFilter = try container.decodeIfPresent(String.self, forKey: .scanServiceFilter) ?? defaults.scanServiceFilter
        connectionTimeout = try container.decodeIfPresent(TimeInterval.self, forKey: .connectionTimeout) ?? defaults.connectionTimeout
        autoReadDescriptors = try container.decodeIfPresent(Bool.self, forKey: .autoReadDescriptors) ?? defaults.autoReadDescriptors
        autoReadCharacteristics = try container.decodeIfPresent(Bool.self, forKey: .autoReadCharacteristics) ?? defaults.autoReadCharacteristics
        confirmWrites = try container.decodeIfPresent(Bool.self, forKey: .confirmWrites) ?? defaults.confirmWrites
        rssiPollInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .rssiPollInterval) ?? defaults.rssiPollInterval
        logCapacity = try container.decodeIfPresent(Int.self, forKey: .logCapacity) ?? defaults.logCapacity
        logAdvertisementChanges = try container.decodeIfPresent(Bool.self, forKey: .logAdvertisementChanges) ?? defaults.logAdvertisementChanges
        logRSSIReadings = try container.decodeIfPresent(Bool.self, forKey: .logRSSIReadings) ?? defaults.logRSSIReadings
        historyMode = try container.decodeIfPresent(HistoryMode.self, forKey: .historyMode) ?? defaults.historyMode
        classicInquiryDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .classicInquiryDuration) ?? defaults.classicInquiryDuration
        systemConnectedServiceUUIDs = try container.decodeIfPresent(String.self, forKey: .systemConnectedServiceUUIDs) ?? defaults.systemConnectedServiceUUIDs
    }
}
