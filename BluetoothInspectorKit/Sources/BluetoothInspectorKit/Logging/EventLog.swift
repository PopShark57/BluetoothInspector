import Foundation

/// Filter applied to the activity log.
public struct EventFilter: Hashable, Sendable {
    public var categories: Set<EventCategory>
    public var searchText: String
    public var deviceID: DeviceID?

    public init(categories: Set<EventCategory> = Set(EventCategory.allCases), searchText: String = "", deviceID: DeviceID? = nil) {
        self.categories = categories
        self.searchText = searchText
        self.deviceID = deviceID
    }

    public func matches(_ event: ActivityEvent) -> Bool {
        guard categories.contains(event.category) else { return false }
        if let deviceID, event.deviceID != deviceID { return false }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if query.isEmpty { return true }
        return SearchMatcher(query).matches(event.searchableText)
    }
}

/// Bounded, append-only log of Bluetooth activity.
///
/// Pure value type: the observable `ActivityLog` wrapper in the workspace
/// decides when to publish snapshots to the UI so bursts of events don't
/// trigger a render per event.
public struct EventLog: Sendable {
    public static let defaultCapacity = 10_000

    private var buffer: RingBuffer<ActivityEvent>
    private var nextID: UInt64 = 1
    /// Total events ever appended, including those evicted.
    public private(set) var totalAppended: UInt64 = 0

    public init(capacity: Int = EventLog.defaultCapacity) {
        buffer = RingBuffer(capacity: capacity)
    }

    public var capacity: Int { buffer.capacity }
    public var count: Int { buffer.count }
    public var events: [ActivityEvent] { buffer.elements }
    public var droppedCount: UInt64 { totalAppended - UInt64(buffer.count) }

    @discardableResult
    public mutating func append(
        _ category: EventCategory,
        _ message: String,
        deviceID: DeviceID? = nil,
        deviceName: String? = nil,
        uuid: BluetoothUUID? = nil,
        data: Data? = nil,
        at timestamp: Date = Date()
    ) -> ActivityEvent {
        let event = ActivityEvent(id: nextID, timestamp: timestamp, category: category, deviceID: deviceID,
                                  deviceName: deviceName, message: message, uuid: uuid, data: data)
        nextID += 1
        totalAppended += 1
        buffer.append(event)
        return event
    }

    public mutating func clear() {
        buffer.removeAll()
    }

    public mutating func setCapacity(_ capacity: Int) {
        buffer.resize(to: capacity)
    }

    public func filtered(_ filter: EventFilter) -> [ActivityEvent] {
        buffer.elements.filter(filter.matches)
    }

    public static func consoleText(_ events: [ActivityEvent]) -> String {
        events.map(\.consoleLine).joined(separator: "\n")
    }
}
