import Foundation

public enum RSSITrend: String, Sendable, Codable {
    case rising
    case falling
    case stable
    case insufficientData

    public var title: String {
        switch self {
        case .rising: "Getting stronger"
        case .falling: "Getting weaker"
        case .stable: "Stable"
        case .insufficientData: "Not enough data"
        }
    }

    public var symbolName: String {
        switch self {
        case .rising: "arrow.up.right"
        case .falling: "arrow.down.right"
        case .stable: "arrow.right"
        case .insufficientData: "questionmark"
        }
    }
}

public struct RSSIStatistics: Hashable, Sendable {
    public let count: Int
    public let current: Int?
    public let average: Double?
    public let minimum: Int?
    public let maximum: Int?
    /// Least-squares slope in dB per second over the window.
    public let slope: Double?
    public let trend: RSSITrend
}

/// Time series of RSSI samples for one device.
///
/// RSSI is a noisy, per-packet signal-strength reading. It is influenced by
/// antenna orientation, obstacles, reflections and the advertiser's TX power,
/// so the app shows it as a relative trend and never converts it to distance.
public struct RSSIHistory: Sendable {
    /// ~15 minutes at 10 samples/s, the fastest rate CoreBluetooth typically
    /// reports with duplicate filtering disabled.
    public static let defaultCapacity = 9_000
    /// Slopes smaller than this (dB/s) count as stable.
    public static let stableThreshold = 0.1

    private var buffer: RingBuffer<RSSISample>

    public init(capacity: Int = RSSIHistory.defaultCapacity) {
        buffer = RingBuffer(capacity: capacity)
    }

    public var samples: [RSSISample] { buffer.elements }
    public var latest: RSSISample? { buffer.last }
    public var count: Int { buffer.count }

    /// Adds a reading; returns false for "unavailable" values (127) which are dropped.
    @discardableResult
    public mutating func record(_ value: Int, at date: Date) -> Bool {
        guard RSSISample.isValid(value) else { return false }
        buffer.append(RSSISample(timestamp: date, value: value))
        return true
    }

    public mutating func clear() { buffer.removeAll() }

    public func samples(in window: TimeInterval, now: Date) -> [RSSISample] {
        let start = now.addingTimeInterval(-window)
        return buffer.elements.filter { $0.timestamp >= start && $0.timestamp <= now }
    }

    public func statistics(window: TimeInterval, now: Date) -> RSSIStatistics {
        Self.statistics(for: samples(in: window, now: now))
    }

    public static func statistics(for samples: [RSSISample]) -> RSSIStatistics {
        guard let first = samples.first else {
            return RSSIStatistics(count: 0, current: nil, average: nil, minimum: nil, maximum: nil, slope: nil, trend: .insufficientData)
        }
        let values = samples.map(\.value)
        let average = Double(values.reduce(0, +)) / Double(values.count)
        var slope: Double?
        var trend = RSSITrend.insufficientData
        if samples.count >= 3 {
            let xs = samples.map { $0.timestamp.timeIntervalSince(first.timestamp) }
            let meanX = xs.reduce(0, +) / Double(xs.count)
            var numerator = 0.0
            var denominator = 0.0
            for (x, y) in zip(xs, values) {
                numerator += (x - meanX) * (Double(y) - average)
                denominator += (x - meanX) * (x - meanX)
            }
            if denominator > 0 {
                let value = numerator / denominator
                slope = value
                trend = abs(value) < stableThreshold ? .stable : (value > 0 ? .rising : .falling)
            }
        }
        return RSSIStatistics(count: samples.count, current: samples.last?.value, average: average,
                              minimum: values.min(), maximum: values.max(), slope: slope, trend: trend)
    }
}

/// Chart time windows offered by the RSSI monitor.
public enum RSSIWindow: Int, CaseIterable, Identifiable, Sendable {
    case thirtySeconds = 30
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900

    public var id: Int { rawValue }
    public var duration: TimeInterval { TimeInterval(rawValue) }

    public var title: String {
        switch self {
        case .thirtySeconds: "30 s"
        case .oneMinute: "1 min"
        case .fiveMinutes: "5 min"
        case .fifteenMinutes: "15 min"
        }
    }
}
