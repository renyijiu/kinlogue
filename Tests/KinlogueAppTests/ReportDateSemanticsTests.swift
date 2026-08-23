import Foundation
import Testing
@testable import KinlogueApp

@Test
func reportDateRoundTripsWithoutCrossingADayInUTCPlusFourteen() throws {
    let timeZone = try #require(TimeZone(secondsFromGMT: 14 * 60 * 60))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let userSelection = try #require(calendar.date(from: DateComponents(
        timeZone: timeZone,
        year: 2026,
        month: 7,
        day: 18,
        hour: 12
    )))

    let canonical = try #require(ReportDateSemantics.canonicalDate(
        from: userSelection,
        timeZone: timeZone
    ))
    let reopenedPickerDate = try #require(ReportDateSemantics.pickerDate(
        from: canonical,
        timeZone: timeZone
    ))

    #expect(ReportDateSemantics.transcription(for: canonical) == "2026-07-18")
    #expect(ReportDateSemantics.canonicalDate(
        from: reopenedPickerDate,
        timeZone: timeZone
    ) == canonical)
}

@Test
func reportDateFormattingUsesTheSelectedAppLocale() throws {
    let canonical = try #require(ReportDateSemantics.canonicalDate(
        from: Date(timeIntervalSince1970: 1_784_332_800),
        timeZone: TimeZone(secondsFromGMT: 0)!
    ))

    #expect(ReportDateSemantics.formatted(
        canonical,
        style: .long,
        locale: Locale(identifier: "en")
    ) == "July 18, 2026")
    #expect(ReportDateSemantics.formatted(
        canonical,
        style: .long,
        locale: Locale(identifier: "zh-Hans")
    ) == "2026年7月18日")
    #expect(ReportDateSemantics.formatted(
        canonical,
        style: .long,
        language: .simplifiedChinese
    ) == "2026年7月18日")
}
