import Foundation

/// A remembered device, stored locally.
public struct SavedDevice: Identifiable, Hashable, Codable, Sendable {
    public let id: DeviceID
    public var name: String?
    public var customName: String?
    public var firstSeen: Date
    public var lastSeen: Date
    public var transport: BluetoothTransport
    public var knownServices: [BluetoothUUID]
    public var manufacturer: String?
    public var isFavorite: Bool
    public var notes: String

    public init(id: DeviceID, name: String?, firstSeen: Date, lastSeen: Date, transport: BluetoothTransport,
                knownServices: [BluetoothUUID] = [], manufacturer: String? = nil, customName: String? = nil,
                isFavorite: Bool = false, notes: String = "") {
        self.id = id
        self.name = name
        self.customName = customName
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.transport = transport
        self.knownServices = knownServices
        self.manufacturer = manufacturer
        self.isFavorite = isFavorite
        self.notes = notes
    }

    public var displayName: String {
        if let customName, !customName.isEmpty { return customName }
        return name ?? "Unnamed"
    }
}

/// The set of remembered devices. Pure value type; persistence is separate.
public struct DeviceHistory: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version = DeviceHistory.currentVersion
    public private(set) var devices: [DeviceID: SavedDevice] = [:]

    public init(devices: [SavedDevice] = []) {
        for device in devices { self.devices[device.id] = device }
    }

    public var all: [SavedDevice] {
        devices.values.sorted { lhs, rhs in
            if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
            return lhs.lastSeen > rhs.lastSeen
        }
    }

    public subscript(id: DeviceID) -> SavedDevice? { devices[id] }

    /// Records an observation, creating the entry if needed. Existing custom
    /// names, notes and favorites are preserved; services accumulate.
    public mutating func record(id: DeviceID, name: String?, transport: BluetoothTransport,
                                services: [BluetoothUUID] = [], manufacturer: String? = nil, at date: Date) {
        if var existing = devices[id] {
            existing.name = name ?? existing.name
            existing.lastSeen = max(existing.lastSeen, date)
            existing.manufacturer = manufacturer ?? existing.manufacturer
            existing.knownServices = Array(Set(existing.knownServices).union(services)).sorted()
            devices[id] = existing
        } else {
            devices[id] = SavedDevice(id: id, name: name, firstSeen: date, lastSeen: date, transport: transport,
                                      knownServices: Array(Set(services)).sorted(), manufacturer: manufacturer)
        }
    }

    public mutating func rename(_ id: DeviceID, to customName: String?) {
        let trimmed = customName?.trimmingCharacters(in: .whitespacesAndNewlines)
        devices[id]?.customName = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    public mutating func setFavorite(_ id: DeviceID, _ isFavorite: Bool) {
        devices[id]?.isFavorite = isFavorite
    }

    public mutating func setNotes(_ id: DeviceID, _ notes: String) {
        devices[id]?.notes = notes
    }

    public mutating func forget(_ id: DeviceID) {
        devices[id] = nil
    }

    public mutating func forgetAll() {
        devices.removeAll()
    }

    public mutating func upsert(_ device: SavedDevice) {
        devices[device.id] = device
    }

    // Stored as an array: JSON objects need string keys, and an array keeps the file diff-friendly.
    private enum CodingKeys: String, CodingKey { case version, devices }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        let list = try container.decode([SavedDevice].self, forKey: .devices)
        for device in list { devices[device.id] = device }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(devices.values.sorted { $0.id < $1.id }, forKey: .devices)
    }
}

/// Persistence boundary for the device history, so tests and previews can use memory.
public protocol DeviceHistoryPersisting: Sendable {
    func load() throws -> DeviceHistory
    func save(_ history: DeviceHistory) throws
}

/// Stores the history as JSON in a file (Application Support in the app).
public struct FileDeviceHistoryStore: DeviceHistoryPersisting {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `~/Library/Application Support/<bundle>/DeviceHistory.json` (inside the
    /// sandbox container when sandboxed).
    public static func defaultURL(appFolder: String = "BluetoothInspector") throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent(appFolder, isDirectory: true).appendingPathComponent("DeviceHistory.json")
    }

    public func load() throws -> DeviceHistory {
        guard FileManager.default.fileExists(atPath: url.path) else { return DeviceHistory() }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DeviceHistory.self, from: data)
    }

    public func save(_ history: DeviceHistory) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(history).write(to: url, options: .atomic)
    }
}

/// In-memory store for tests and previews.
public final class InMemoryDeviceHistoryStore: DeviceHistoryPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: DeviceHistory
    public private(set) var saveCount = 0

    public init(_ history: DeviceHistory = DeviceHistory()) {
        stored = history
    }

    public func load() throws -> DeviceHistory { lock.withLock { stored } }

    public func save(_ history: DeviceHistory) throws {
        lock.withLock {
            stored = history
            saveCount += 1
        }
    }
}
