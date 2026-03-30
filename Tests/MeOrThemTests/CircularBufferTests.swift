@testable import MeOrThemCore

func runCircularBufferTests() {
    suite("CircularBuffer") {
        var buf = CircularBuffer<Int>(capacity: 5)
        [1, 2, 3].forEach { buf.append($0) }
        expectEqual(buf.toArray(), [1, 2, 3], "fill without wrap")
        expectEqual(buf.count, 3, "count 3")

        var buf2 = CircularBuffer<Int>(capacity: 3)
        [1, 2, 3, 4, 5].forEach { buf2.append($0) }
        expectEqual(buf2.toArray(), [3, 4, 5], "wrap-around keeps newest 3")
        expectEqual(buf2.count, 3, "count stays at capacity")

        var buf3 = CircularBuffer<Int>(capacity: 4)
        [10, 20, 30, 40, 50].forEach { buf3.append($0) }
        let arr = buf3.toArray()
        expectEqual(arr, [20, 30, 40, 50], "chronological order after wrap")

        var buf4 = CircularBuffer<Int>(capacity: 3)
        buf4.append(7); buf4.append(8)
        expectEqual(buf4.latest, 8, "latest returns last inserted")

        let empty = CircularBuffer<Int>(capacity: 5)
        expectEqual(empty.toArray(), [], "empty buffer")
        expectNil(empty.latest, "empty latest is nil")

        var buf5 = CircularBuffer<Int>(capacity: 100)
        (1...20).forEach { buf5.append($0) }
        expectEqual(buf5.last(5), [16, 17, 18, 19, 20], "last(5)")

        var buf6 = CircularBuffer<Int>(capacity: 1)
        buf6.append(1); buf6.append(2)
        expectEqual(buf6.toArray(), [2], "capacity-1 keeps only latest")

        var buf7 = CircularBuffer<Int>(capacity: 3)
        [1, 2, 3].forEach { buf7.append($0) }
        buf7.clear()
        expectEqual(buf7.count, 0, "clear resets count")
        expectEqual(buf7.toArray(), [], "clear empties array")
    }
}
