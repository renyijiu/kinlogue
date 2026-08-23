import Foundation

enum ReportDateSemantics {
    enum DisplayStyle {
        case medium
        case long
    }

    private static let storageTimeZone = TimeZone(secondsFromGMT: 0)!

    static func canonicalDate(
        from userSelection: Date,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> Date? {
        let components = calendar(timeZone: timeZone)
            .dateComponents([.year, .month, .day], from: userSelection)
        guard let year = components.year,
              let month = components.month,
              let day = components.day else {
            return nil
        }
        return storageCalendar.date(from: DateComponents(
            timeZone: storageTimeZone,
            year: year,
            month: month,
            day: day,
            hour: 12
        ))
    }

    static func pickerDate(
        from canonicalDate: Date,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> Date? {
        let components = storageCalendar.dateComponents(
            [.year, .month, .day],
            from: canonicalDate
        )
        guard let year = components.year,
              let month = components.month,
              let day = components.day else {
            return nil
        }
        let userCalendar = calendar(timeZone: timeZone)
        return userCalendar.date(from: DateComponents(
            timeZone: timeZone,
            year: year,
            month: month,
            day: day,
            hour: 12
        ))
    }

    static func transcription(for canonicalDate: Date) -> String? {
        let components = storageCalendar.dateComponents(
            [.year, .month, .day],
            from: canonicalDate
        )
        guard let year = components.year,
              let month = components.month,
              let day = components.day else {
            return nil
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func formatted(
        _ canonicalDate: Date,
        style: DisplayStyle,
        language: AppLanguage = AppLocalization.selectedLanguage()
    ) -> String {
        formatted(
            canonicalDate,
            style: style,
            locale: AppLocalization.locale(for: language)
        )
    }

    static func formatted(
        _ canonicalDate: Date,
        style: DisplayStyle,
        locale: Locale
    ) -> String {
        let format = Date.FormatStyle(
            date: style == .medium ? .abbreviated : .long,
            time: .omitted,
            locale: locale,
            calendar: storageCalendar,
            timeZone: storageTimeZone
        )
        return canonicalDate.formatted(format)
    }

    private static var storageCalendar: Calendar {
        calendar(timeZone: storageTimeZone)
    }

    private static func calendar(timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}
