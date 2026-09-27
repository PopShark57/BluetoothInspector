import Foundation
import Observation

/// Observable wrapper around `EventLog` that publishes snapshots to the UI at
/// a bounded rate.
///
/// Appending is O(1) and never touches observed state; `flush()` (driven by
/// the workspace's UI tick) copies the buffer into `snapshot` only when
/// something changed and the console isn't paused. That keeps notification
/// bursts from re-rendering the console hundreds of times per second.
@MainActor
@Observable
public final class ActivityLog {
    @ObservationIgnored private var log: EventLog
    @ObservationIgnored private var isDirty = false

    /// What the console displays. Frozen while paused.
    public private(set) var snapshot: [ActivityEvent] = []
    public var isPaused = false {
        didSet { if !isPaused { flush() } }
    }
    public private(set) var totalCount: UInt64 = 0
    public private(set) var errorCount = 0

    /// Called for every event (the app mirrors events to OSLog).
    @ObservationIgnored public var mirror: (@MainActor (ActivityEvent) -> Void)?

    public init(capacity: Int = EventLog.defaultCapacity) {
        log = EventLog(capacity: capacity)
    }

    public var capacity: Int { log.capacity }
    /// Every retained event, including ones not yet published.
    public var allEvents: [ActivityEvent] { log.events }

    @discardableResult
    public func append(
        _ category: EventCategory,
        _ message: String,
        deviceID: DeviceID? = nil,
        deviceName: String? = nil,
        uuid: BluetoothUUID? = nil,
        data: Data? = nil,
        at date: Date = Date()
    ) -> ActivityEvent {
        let event = log.append(category, message, deviceID: deviceID, deviceName: deviceName, uuid: uuid, data: data, at: date)
        if category == .error { errorCount += 1 }
        isDirty = true
        mirror?(event)
        return event
    }

    /// Publishes pending events. Returns true if the snapshot changed.
    @discardableResult
    public func flush() -> Bool {
        guard isDirty, !isPaused else { return false }
        snapshot = log.events
        totalCount = log.totalAppended
        isDirty = false
        return true
    }

    public func clear() {
        log.clear()
        errorCount = 0
        isDirty = true
        let wasPaused = isPaused
        isPaused = false
        flush()
        isPaused = wasPaused
    }

    public func setCapacity(_ capacity: Int) {
        guard capacity != log.capacity else { return }
        log.setCapacity(capacity)
        isDirty = true
    }

    public func events(matching filter: EventFilter) -> [ActivityEvent] {
        snapshot.filter(filter.matches)
    }
}
