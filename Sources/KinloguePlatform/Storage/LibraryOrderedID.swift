import Foundation
import os

/// Makes identifiers that sort in the order they were made.
///
/// Draft lists and automatic recovery page by `draft_id`, so the identifier is what puts a newer
/// import after the older ones; there is no separate ordering column. The layout is UUID version 7:
/// the first 48 bits are the creation time in milliseconds, the next 12 count identifiers made
/// within one millisecond, and the rest is random. Stored bytes compare in the same order as the
/// identifiers were made, including when the system clock steps backwards while the App runs.
/// Across launches the order follows the clock.
final class LibraryOrderedIDGenerator: Sendable {
    static let shared = LibraryOrderedIDGenerator()

    private struct State: Sendable {
        var millisecond: UInt64 = 0
        var sequence: UInt16 = 0
    }
    private static let sequenceLimit: UInt16 = 1 << 12
    private let state = OSAllocatedUnfairLock(initialState: State())

    func next(now: Date = Date()) -> UUID {
        let clock = UInt64(max(0, now.timeIntervalSince1970 * 1_000))
        let (millisecond, sequence) = state.withLock { state -> (UInt64, UInt16) in
            if clock > state.millisecond {
                state.millisecond = clock
                state.sequence = 0
            } else {
                state.sequence += 1
                if state.sequence == Self.sequenceLimit {
                    // More identifiers than one millisecond holds: borrow the next one.
                    state.millisecond += 1
                    state.sequence = 0
                }
            }
            return (state.millisecond, state.sequence)
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<6 {
            bytes[index] = UInt8(truncatingIfNeeded: millisecond >> UInt64(8 * (5 - index)))
        }
        bytes[6] = 0x70 | UInt8(truncatingIfNeeded: sequence >> 8)
        bytes[7] = UInt8(truncatingIfNeeded: sequence)
        var generator = SystemRandomNumberGenerator()
        for index in 8..<16 { bytes[index] = UInt8.random(in: .min ... .max, using: &generator) }
        bytes[8] = 0x80 | (bytes[8] & 0x3F)
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
