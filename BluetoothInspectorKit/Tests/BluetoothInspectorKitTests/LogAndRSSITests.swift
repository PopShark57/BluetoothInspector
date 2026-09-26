import Foundation
import Testing
@testable import BluetoothInspectorKit

@Suite("Ring buffer and event log")
struct EventLogTests {
    @Test func ringBufferOverwritesOldest() {
        var buffer = RingBuffer<Int>(capacity: 3)
        for value in 1...5 { buffer.append(value) }
        #expect(buffer.elements == [3, 4, 5])
        #expect(buffer.last == 5)
        #expect(buffer.count == 3)
        buffer.resize(to: 2)
        #expect(buffer.elements == [4, 5])
        buffer.resize(to: 4)
        buffer.append(6)
        #expect(buffer.elements == [4, 5, 6])
        buffer.removeAll()
        #expect(buffer.isEmpty && buffer.last == nil)
    }

    @Test func logKeepsNewestEventsAndCountsDrops() {
        var log = EventLog(capacity: 1000)
        for index in 0..<5000 {
            log.append(.notify, "event \(index)")
        }
        #expect(log.count == 1000)
        #expect(log.totalAppended == 5000)
        #expect(log.droppedCount == 4000)
        #expect(log.events.first?.message == "event 4000")
        #expect(log.events.last?.id == 5000)
    }

    @Test func filtersByCategoryDeviceAndText() {
        var log = EventLog()
        let device = DeviceID.lowEnergy(UUID())
        log.append(.scan, "Found R11M", deviceID: device, deviceName: "R11M")
        log.append(.notify, "2A37  00 48", deviceID: device, uuid: BluetoothUUID(uint16: 0x2A37), data: Data([0x00, 0x48]))
        log.append(.error, "Write failed")
        #expect(log.filtered(EventFilter(categories: [.notify])).count == 1)
        #expect(log.filtered(EventFilter(searchText: "heart rate")).count == 1)
        #expect(log.filtered(EventFilter(searchText: "0048")).count == 1)
        #expect(log.filtered(EventFilter(deviceID: device)).count == 2)
        #expect(log.filtered(EventFilter(categories: [.error], searchText: "write")).count == 1)
    }

    @Test func consoleLineFormat() {
        var components = DateComponents()
        components.year = 2026; components.month = 1; components.day = 2
        components.hour = 18; components.minute = 42; components.second = 4; components.nanosecond = 19_000_000
        let date = Calendar.current.date(from: components) ?? Date()
        var log = EventLog()
        let event = log.append(.notify, "2A37  00 48", at: date)
        #expect(event.consoleLine == "18:42:04.019  NOTIFY   2A37  00 48")
    }

    @Test @MainActor func activityLogPublishesOnFlushAndHonorsPause() {
        let log = ActivityLog(capacity: 100)
        log.append(.scan, "one")
        #expect(log.snapshot.isEmpty)
        #expect(log.flush())
        #expect(log.snapshot.count == 1)
        log.isPaused = true
        log.append(.error, "two")
        #expect(!log.flush())
        #expect(log.snapshot.count == 1)
        #expect(log.allEvents.count == 2)
        #expect(log.errorCount == 1)
        log.isPaused = false
        #expect(log.snapshot.count == 2)
        log.clear()
        #expect(log.snapshot.isEmpty && log.errorCount == 0)
    }

    @Test @MainActor func mirrorSeesEveryEvent() {
        let log = ActivityLog()
        var mirrored: [String] = []
        log.mirror = { mirrored.append($0.message) }
        log.append(.system, "a")
        log.append(.system, "b")
        #expect(mirrored == ["a", "b"])
    }
}

@Suite("RSSI history")
struct RSSITests {
    let start = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test func dropsUnavailableReadings() {
        var history = RSSIHistory()
        let unavailable = history.record(127, at: start)
        let valid = history.record(-60, at: start)
        #expect(!unavailable)
        #expect(valid)
        #expect(history.count == 1)
    }

    @Test func statisticsAndRisingTrend() {
        var history = RSSIHistory()
        for second in 0..<10 {
            history.record(-80 + second * 2, at: start.addingTimeInterval(Double(second)))
        }
        let stats = history.statistics(window: 60, now: start.addingTimeInterval(9))
        #expect(stats.count == 10)
        #expect(stats.current == -62)
        #expect(stats.minimum == -80)
        #expect(stats.maximum == -62)
        #expect(stats.average == -71)
        #expect(stats.trend == .rising)
        #expect(abs((stats.slope ?? 0) - 2) < 1e-9)
    }

    @Test func windowExcludesOldSamples() {
        var history = RSSIHistory()
        history.record(-90, at: start)
        history.record(-50, at: start.addingTimeInterval(100))
        let stats = history.statistics(window: 30, now: start.addingTimeInterval(100))
        #expect(stats.count == 1)
        #expect(stats.trend == .insufficientData)
    }

    @Test func stableTrend() {
        let samples = (0..<20).map { RSSISample(timestamp: start.addingTimeInterval(Double($0)), value: $0.isMultiple(of: 2) ? -60 : -61) }
        #expect(RSSIHistory.statistics(for: samples).trend == .stable)
    }
}
