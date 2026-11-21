import Synchronization

/// A lock-free, wait-free single-producer / single-consumer (SPSC) ring buffer for trivially copyable samples.
///
/// Intended for real-time audio threads: the producer (a Core Audio IO / tap callback) calls ``write(_:)`` and never
/// allocates, locks, or blocks; the consumer (a normal queue/task) calls ``read(into:)``.
///
/// ## Contract
/// - Exactly one thread may call the producer API (`write`) and exactly one thread (possibly different) may call the
///   consumer API (`read`, `discard`). Calling a producer method from two threads, or a consumer method from two
///   threads, is a data race. `availableToRead`, `availableToWrite` and `droppedCount` may be read from either side.
/// - Capacity is rounded up to a power of two so indices are wrapped with a mask rather than a division.
/// - On overflow the producer **never waits**: it stores what fits, rejects the rest and adds the rejected count to
///   ``droppedCount`` (the caller logs the metric). Newest-data-wins policies belong in the consumer.
///
/// ## Memory ordering
/// `head` counts every element ever written, `tail` every element ever read (monotonic, never wrapped; `Int` cannot
/// overflow in practice). Each index has exactly one writer:
/// - The producer loads its own `head` *relaxed* (it is the only writer), loads `tail` with *acquire* so that the
///   consumer's reads of a slot happen-before the producer reuses that slot, writes the payload with plain stores, then
///   publishes with a *release* store to `head`.
/// - The consumer mirrors this: own `tail` relaxed, `head` acquire (so the payload written before the producer's
///   release store is visible), copies the payload out, then frees the slots with a *release* store to `tail`.
///
/// A stale (smaller) `tail` seen by the producer only makes it conservatively report less free space; a stale `head`
/// seen by the consumer only makes it see less data. Neither can corrupt data.
public final class RingBuffer<Element: BitwiseCopyable & Sendable>: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Element>
    private let mask: Int
    /// Number of slots (a power of two).
    public let capacity: Int
    private let head = Atomic<Int>(0)  // total written; producer-owned
    private let tail = Atomic<Int>(0)  // total read; consumer-owned
    private let dropped = Atomic<Int>(0)

    /// Creates a ring buffer able to hold at least `minimumCapacity` elements (rounded up to a power of two).
    ///
    /// - Parameters:
    ///   - minimumCapacity: Desired capacity in elements; values below 2 are raised to 2.
    ///   - initialValue: Value the storage is initialised with (storage is never reallocated afterwards).
    public init(minimumCapacity: Int, initialValue: Element) {
        var cap = 2
        while cap < minimumCapacity { cap <<= 1 }
        capacity = cap
        mask = cap - 1
        storage = .allocate(capacity: cap)
        storage.initialize(repeating: initialValue, count: cap)
    }

    deinit {
        storage.deallocate()
    }

    /// Elements currently readable.
    public var availableToRead: Int { head.load(ordering: .acquiring) - tail.load(ordering: .acquiring) }
    /// Free slots currently writable.
    public var availableToWrite: Int { capacity - availableToRead }
    /// Total number of elements the producer had to reject because the buffer was full.
    public var droppedCount: Int { dropped.load(ordering: .relaxed) }

    /// Producer side. Real-time safe: no allocation, no locks, no syscalls.
    ///
    /// - Returns: The number of elements stored (may be less than `source.count` when full; the rest is counted as dropped).
    @discardableResult
    public func write(_ source: UnsafeBufferPointer<Element>) -> Int {
        guard let base = source.baseAddress, !source.isEmpty else { return 0 }
        let head = self.head.load(ordering: .relaxed)
        let tail = self.tail.load(ordering: .acquiring)
        let count = min(source.count, capacity - (head - tail))
        if count < source.count { dropped.add(source.count - count, ordering: .relaxed) }
        if count <= 0 { return 0 }
        let start = head & mask
        let first = min(count, capacity - start)
        (storage + start).update(from: base, count: first)
        if count > first { storage.update(from: base + first, count: count - first) }
        self.head.store(head + count, ordering: .releasing)
        return count
    }

    /// Consumer side. Copies up to `destination.count` elements out.
    ///
    /// - Returns: The number of elements copied (0 when empty).
    @discardableResult
    public func read(into destination: UnsafeMutableBufferPointer<Element>) -> Int {
        guard let base = destination.baseAddress, !destination.isEmpty else { return 0 }
        let tail = self.tail.load(ordering: .relaxed)
        let head = self.head.load(ordering: .acquiring)
        let count = min(destination.count, head - tail)
        if count <= 0 { return 0 }
        let start = tail & mask
        let first = min(count, capacity - start)
        base.update(from: storage + start, count: first)
        if count > first { (base + first).update(from: storage, count: count - first) }
        self.tail.store(tail + count, ordering: .releasing)
        return count
    }

    /// Consumer side. Convenience that reads up to `maxCount` elements into a new array (allocates; not for RT threads).
    public func read(maxCount: Int) -> [Element] {
        let n = min(maxCount, availableToRead)
        guard n > 0 else { return [] }
        return [Element](unsafeUninitializedCapacity: n) { buffer, initialized in
            initialized = read(into: buffer)
        }
    }

    /// Consumer side. Drops up to `count` unread elements (e.g. to resynchronise after overload).
    @discardableResult
    public func discard(_ count: Int) -> Int {
        let tail = self.tail.load(ordering: .relaxed)
        let head = self.head.load(ordering: .acquiring)
        let n = max(0, min(count, head - tail))
        if n > 0 { self.tail.store(tail + n, ordering: .releasing) }
        return n
    }
}

extension RingBuffer where Element == Float {
    /// Creates a Float ring buffer zero-initialised, holding at least `minimumCapacity` samples.
    public convenience init(minimumCapacity: Int) {
        self.init(minimumCapacity: minimumCapacity, initialValue: 0)
    }
}
