import Foundation

/// Fixed-capacity FIFO that overwrites its oldest element. O(1) append, no
/// reallocation once full — suitable for high-rate notification and RSSI
/// streams that must not grow without bound.
public struct RingBuffer<Element>: Sequence {
    public private(set) var capacity: Int
    private var storage: [Element] = []
    private var head = 0

    public init(capacity: Int) {
        self.capacity = Swift.max(1, capacity)
        storage.reserveCapacity(self.capacity)
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }

    public mutating func append(_ element: Element) {
        if storage.count < capacity {
            storage.append(element)
        } else {
            storage[head] = element
            head = (head + 1) % capacity
        }
    }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
    }

    /// Changes capacity, keeping the newest elements.
    public mutating func resize(to newCapacity: Int) {
        let elements = Array(self)
        capacity = Swift.max(1, newCapacity)
        storage = Array(elements.suffix(capacity))
        storage.reserveCapacity(capacity)
        head = 0
    }

    /// Oldest first.
    public var elements: [Element] {
        guard storage.count == capacity, head != 0 else { return storage }
        return Array(storage[head...] + storage[..<head])
    }

    public var last: Element? {
        guard !storage.isEmpty else { return nil }
        return storage.count < capacity || head == 0 ? storage.last : storage[head - 1]
    }

    public func makeIterator() -> IndexingIterator<[Element]> {
        elements.makeIterator()
    }
}

extension RingBuffer: Sendable where Element: Sendable {}
extension RingBuffer: Equatable where Element: Equatable {
    public static func == (lhs: RingBuffer, rhs: RingBuffer) -> Bool {
        lhs.capacity == rhs.capacity && lhs.elements == rhs.elements
    }
}
