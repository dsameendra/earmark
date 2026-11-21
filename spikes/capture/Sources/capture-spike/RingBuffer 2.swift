import Synchronization

/// Single-producer / single-consumer lock-free Float ring buffer.
/// Producer = audio render/IO thread (never allocates, never locks). Consumer = a normal queue.
final class SPSCRing: @unchecked Sendable {
    private let cap: Int
    private let buf: UnsafeMutablePointer<Float>
    private let head = Atomic<Int>(0) // total written
    private let tail = Atomic<Int>(0) // total read
    let dropped = Atomic<Int>(0)

    init(capacityFrames: Int) {
        cap = capacityFrames
        buf = .allocate(capacity: capacityFrames)
        buf.initialize(repeating: 0, count: capacityFrames)
    }
    deinit { buf.deallocate() }

    /// Real-time safe. Drops (and counts) samples on overflow instead of blocking.
    @discardableResult
    func write(_ src: UnsafePointer<Float>, count n: Int) -> Int {
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        let n2 = min(n, cap - (h - t))
        if n2 < n { dropped.add(n - n2, ordering: .relaxed) }
        if n2 <= 0 { return 0 }
        for i in 0..<n2 { buf[(h + i) % cap] = src[i] }
        head.store(h + n2, ordering: .releasing)
        return n2
    }

    func read(into dst: UnsafeMutablePointer<Float>, max n: Int) -> Int {
        let t = tail.load(ordering: .relaxed)
        let h = head.load(ordering: .acquiring)
        let n2 = min(n, h - t)
        if n2 <= 0 { return 0 }
        for i in 0..<n2 { dst[i] = buf[(t + i) % cap] }
        tail.store(t + n2, ordering: .releasing)
        return n2
    }
}
