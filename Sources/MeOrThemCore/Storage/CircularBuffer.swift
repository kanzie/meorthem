import Foundation

/// Fixed-capacity FIFO ring buffer. When full, oldest element is overwritten.
/// Not thread-safe — must be accessed from a single actor (@MainActor).
struct CircularBuffer<T> {
    private var storage: ContiguousArray<T?>
    private var writeIndex: Int = 0
    private(set) var count: Int = 0
    let capacity: Int

    init(capacity: Int) {
        precondition(capacity > 0, "Capacity must be positive")
        self.capacity = capacity
        storage = ContiguousArray(repeating: nil, count: capacity)
    }

    mutating func append(_ element: T) {
        storage[writeIndex % capacity] = element
        writeIndex &+= 1
        if count < capacity { count &+= 1 }
    }

    /// Returns elements in chronological order (oldest → newest).
    func toArray() -> [T] {
        guard count > 0 else { return [] }
        let startSlot = count == capacity ? writeIndex % capacity : 0
        return (0..<count).map { storage[(startSlot + $0) % capacity]! }
    }

    /// Last N elements in chronological order.
    func last(_ n: Int) -> [T] {
        guard count > 0 else { return [] }
        let take = min(n, count)
        let startSlot = (writeIndex - take + capacity * 2) % capacity
        return (0..<take).map { storage[(startSlot + $0) % capacity]! }
    }

    var latest: T? {
        guard count > 0 else { return nil }
        return storage[(writeIndex - 1 + capacity) % capacity]
    }

    mutating func clear() {
        storage = ContiguousArray(repeating: nil, count: capacity)
        writeIndex = 0
        count = 0
    }
}
