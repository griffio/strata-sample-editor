import Foundation
import StrataAtomics
import os

/// Converts between mach host ticks and seconds.
enum HostClock {
    private static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    static var now: UInt64 { mach_absolute_time() }

    static func seconds(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }

    static func ticks(_ seconds: Double) -> UInt64 {
        UInt64(max(0, seconds) * 1e9 * Double(timebase.denom) / Double(timebase.numer))
    }

    static func signedSeconds(from a: UInt64, to b: UInt64) -> Double {
        b >= a ? seconds(b - a) : -seconds(a - b)
    }
}

/// An `os_unfair_lock` with a stable address (required for correct use from Swift).
final class UnfairLock {
    private let ptr: UnsafeMutablePointer<os_unfair_lock>

    init() {
        ptr = .allocate(capacity: 1)
        ptr.initialize(to: os_unfair_lock())
    }

    deinit { ptr.deallocate() }

    func lock() { os_unfair_lock_lock(ptr) }
    func unlock() { os_unfair_lock_unlock(ptr) }
    /// Safe to call from the real-time thread: never blocks.
    func tryLock() -> Bool { os_unfair_lock_trylock(ptr) }

    @discardableResult
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}

/// A block of atomically accessed 64-bit integers.
final class AtomicInts {
    let ptr: UnsafeMutablePointer<Int64>
    let count: Int

    init(count: Int, value: Int64 = 0) {
        self.count = count
        ptr = .allocate(capacity: count)
        ptr.initialize(repeating: value, count: count)
    }

    deinit { ptr.deallocate() }

    subscript(i: Int) -> Int64 {
        get { sa_load_i64(ptr + i) }
        set { sa_store_i64(ptr + i, newValue) }
    }
}

/// A block of floats used for lock-free metering (writer keeps the max, reader resets).
final class AtomicFloats {
    let ptr: UnsafeMutablePointer<Float>
    let count: Int

    init(count: Int) {
        self.count = count
        ptr = .allocate(capacity: count)
        ptr.initialize(repeating: 0, count: count)
    }

    deinit { ptr.deallocate() }

    func storeMax(_ i: Int, _ v: Float) { sa_max_f32(ptr + i, v) }
    func take(_ i: Int) -> Float { sa_exchange_zero_f32(ptr + i) }
    func load(_ i: Int) -> Float { sa_load_f32(ptr + i) }
    func store(_ i: Int, _ v: Float) { sa_store_f32(ptr + i, v) }
}

/// Single-producer / single-consumer lock-free stereo ring buffer.
final class StereoRingBuffer {
    let capacity: Int
    private let mask: Int
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private let indices = AtomicInts(count: 2)   // 0: write, 1: read (monotonic)

    init(minimumCapacity: Int) {
        var c = 1
        while c < minimumCapacity { c <<= 1 }
        capacity = c
        mask = c - 1
        left = .allocate(capacity: c)
        right = .allocate(capacity: c)
        left.initialize(repeating: 0, count: c)
        right.initialize(repeating: 0, count: c)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    var availableToRead: Int { Int(indices[0] - indices[1]) }
    var totalWritten: Int64 { indices[0] }

    /// Producer side. Drops samples on overflow (returns the number written).
    @discardableResult
    func write(left l: UnsafePointer<Float>, right r: UnsafePointer<Float>, count: Int) -> Int {
        let w = indices[0], rd = indices[1]
        let free = capacity - Int(w - rd)
        let n = min(count, free)
        guard n > 0 else { return 0 }
        let start = Int(w) & mask
        let first = min(n, capacity - start)
        (left + start).assign(from: l, count: first)
        (right + start).assign(from: r, count: first)
        if n > first {
            left.assign(from: l + first, count: n - first)
            right.assign(from: r + first, count: n - first)
        }
        indices[0] = w + Int64(n)
        return n
    }

    /// Consumer side.
    @discardableResult
    func read(left l: UnsafeMutablePointer<Float>, right r: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let w = indices[0], rd = indices[1]
        let n = min(count, Int(w - rd))
        guard n > 0 else { return 0 }
        let start = Int(rd) & mask
        let first = min(n, capacity - start)
        l.assign(from: left + start, count: first)
        r.assign(from: right + start, count: first)
        if n > first {
            (l + first).assign(from: left, count: n - first)
            (r + first).assign(from: right, count: n - first)
        }
        indices[1] = rd + Int64(n)
        return n
    }

    /// Consumer side: discard so that at most `keep` frames remain (latency control).
    func skip(keeping keep: Int) {
        let w = indices[0], rd = indices[1]
        if Int(w - rd) > keep { indices[1] = w - Int64(keep) }
    }

    func reset() { indices[1] = indices[0] }
}
