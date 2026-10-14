import Foundation
import Testing
@testable import KinloguePlatform

// Draft lists page by identifier, so stored identifier bytes have to compare in creation order.

@Test
func orderedIdentifiersCompareInCreationOrderWithinOneMillisecond() {
    let generator = LibraryOrderedIDGenerator()
    let instant = Date(timeIntervalSince1970: 1_786_000_000)
    // More than one millisecond can number, so the generator has to borrow the next one.
    let identifiers = (0..<10_000).map { _ in generator.next(now: instant) }

    #expect(Set(identifiers).count == identifiers.count)
    #expect(zip(identifiers, identifiers.dropFirst()).allSatisfy { precedes($0, $1) })
}

@Test
func orderedIdentifiersKeepTheirOrderWhenTheClockStepsBackwards() {
    let generator = LibraryOrderedIDGenerator()
    let later = generator.next(now: Date(timeIntervalSince1970: 1_786_000_100))
    let afterClockStep = generator.next(now: Date(timeIntervalSince1970: 1_786_000_000))
    let afterClockRecovers = generator.next(now: Date(timeIntervalSince1970: 1_786_000_200))

    #expect(precedes(later, afterClockStep))
    #expect(precedes(afterClockStep, afterClockRecovers))
}

@Test
func orderedIdentifiersCarryTheCreationTimeAndTheVersionSevenLayout() {
    let milliseconds: UInt64 = 1_786_000_000_123
    let identifier = LibraryOrderedIDGenerator().next(now: Date(timeIntervalSince1970: Double(milliseconds) / 1_000))
    let bytes = identifier.sqliteBytes

    #expect(bytes.prefix(6).reduce(UInt64(0)) { $0 << 8 | UInt64($1) } == milliseconds)
    #expect(bytes[6] >> 4 == 7)
    #expect(bytes[8] >> 6 == 0b10)
}

private func precedes(_ lhs: UUID, _ rhs: UUID) -> Bool {
    lhs.sqliteBytes.lexicographicallyPrecedes(rhs.sqliteBytes)
}
