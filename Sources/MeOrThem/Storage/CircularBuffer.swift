import Foundation

/// Fixed-capacity FIFO ring buffer. When full, oldest element is overwritten.
/// Not thread-safe — must be accessed from a single actor (@MainActor).
///
/// Optimization notes:
/// - `writeIndex` is kept bounded to `[0, capacity)` — avoids modulo in append.
/// - `toArray()` and `last()` use two-slice copy to avoid per-element modulo.
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
        storage[writeIndex] = element
        writeIndex += 1
        if writeIndex == capacity { writeIndex = 0 }   // bounds-wrap: cheaper than % on every call
        if count < capacity { count += 1 }
    }

    /// Returns all elements in chronological order (oldest → newest).
    func toArray() -> [T] {
        guard count > 0 else { return [] }
        if count < capacity {
            // Buffer hasn't wrapped yet — data lives in storage[0..<count]
            return storage[0..<count].map { $0! }
        }
        // Buffer is full; oldest element is at writeIndex, newest is at writeIndex-1.
        var result = [T]()
        result.reserveCapacity(capacity)
        if writeIndex == 0 {
            for elem in storage { result.append(elem!) }
        } else {
            for i in writeIndex..<capacity { result.append(storage[i]!) }
            for i in 0..<writeIndex       { result.append(storage[i]!) }
        }
        return result
    }

    /// Last N elements in chronological order (oldest first within the N).
    func last(_ n: Int) -> [T] {
        guard count > 0 else { return [] }
        let take = min(n, count)
        // Start slot: with bounded writeIndex, only one capacity addition needed.
        let startSlot = (writeIndex - take + capacity) % capacity
        if startSlot + take <= capacity {
            // Contiguous slice — no wrap needed
            return storage[startSlot..<(startSlot + take)].map { $0! }
        }
        // Wrapped: two slices
        let firstLen = capacity - startSlot
        var result = [T]()
        result.reserveCapacity(take)
        for i in startSlot..<capacity     { result.append(storage[i]!) }
        for i in 0..<(take - firstLen)    { result.append(storage[i]!) }
        return result
    }

    var latest: T? {
        guard count > 0 else { return nil }
        let idx = writeIndex == 0 ? capacity - 1 : writeIndex - 1
        return storage[idx]
    }

    mutating func clear() {
        storage = ContiguousArray(repeating: nil, count: capacity)
        writeIndex = 0
        count = 0
    }
}
