import Foundation

public enum EventCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case scan
    case rssi
    case connection
    case service
    case read
    case write
    case notify
    case decode
    case classic
    case system
    case error

    public var id: String { rawValue }

    /// Fixed-width tag used in the console (`SCAN    `).
    public var tag: String {
        switch self {
        case .scan: "SCAN"
        case .rssi: "RSSI"
        case .connection: "CONNECT"
        case .service: "SERVICE"
        case .read: "READ"
        case .write: "WRITE"
        case .notify: "NOTIFY"
        case .decode: "DECODE"
        case .classic: "CLASSIC"
        case .system: "SYSTEM"
        case .error: "ERROR"
        }
    }

    public var title: String {
        switch self {
        case .scan: "Scan"
        case .rssi: "RSSI"
        case .connection: "Connection"
        case .service: "Services"
        case .read: "Reads"
        case .write: "Writes"
        case .notify: "Notifications"
        case .decode: "Decoded"
        case .classic: "Classic"
        case .system: "System"
        case .error: "Errors"
        }
    }

    public var symbolName: String {
        switch self {
        case .scan: "dot.radiowaves.left.and.right"
        case .rssi: "cellularbars"
        case .connection: "link"
        case .service: "list.bullet.indent"
        case .read: "arrow.down.circle"
        case .write: "arrow.up.circle"
        case .notify: "bell"
        case .decode: "text.magnifyingglass"
        case .classic: "antenna.radiowaves.left.and.right"
        case .system: "gearshape"
        case .error: "exclamationmark.triangle"
        }
    }
}

/// One entry in the activity log.
public struct ActivityEvent: Identifiable, Hashable, Codable, Sendable {
    /// Monotonic sequence number assigned by the log.
    public let id: UInt64
    public let timestamp: Date
    public let category: EventCategory
    public let deviceID: DeviceID?
    public let deviceName: String?
    public let message: String
    public let uuid: BluetoothUUID?
    public let data: Data?

    public init(
        id: UInt64,
        timestamp: Date,
        category: EventCategory,
        deviceID: DeviceID? = nil,
        deviceName: String? = nil,
        message: String,
        uuid: BluetoothUUID? = nil,
        data: Data? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.message = message
        self.uuid = uuid
        self.data = data
    }

    // DateFormatter is expensive to create and not Sendable; one per thread.
    private static func timeFormatter() -> DateFormatter {
        let key = "BluetoothInspectorKit.ActivityEvent.timeFormatter"
        if let cached = Thread.current.threadDictionary[key] as? DateFormatter { return cached }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        Thread.current.threadDictionary[key] = formatter
        return formatter
    }

    public var timeString: String { Self.timeFormatter().string(from: timestamp) }

    /// Console line: `18:42:04.019  NOTIFY   2A37  00 48`.
    public var consoleLine: String {
        var line = "\(timeString)  \(category.tag.padding(toLength: 8, withPad: " ", startingAt: 0)) "
        if let deviceName { line += "[\(deviceName)] " }
        line += message
        return line
    }

    /// Text used by console search.
    public var searchableText: String {
        [message, deviceName ?? "", deviceID?.identifierString ?? "", uuid?.shortString ?? "",
         uuid?.sigName ?? "", data?.hexString ?? "", category.tag].joined(separator: " ")
    }
}
