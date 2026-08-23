import AppKit
import Foundation
import SwiftUI
import Testing

@testable import KinlogueApp

@MainActor
struct LocalizedDatePickerTests {
    @Test
    func nativePickerUsesTheAppLanguageInsteadOfTheSystemRegion() throws {
        var englishRegionalCalendar = Calendar(identifier: .iso8601)
        englishRegionalCalendar.locale = Locale(identifier: "en_CN")
        englishRegionalCalendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        englishRegionalCalendar.firstWeekday = 2
        englishRegionalCalendar.minimumDaysInFirstWeek = 4

        let locale = AppLocalization.locale(for: .simplifiedChinese)
        let calendar = AppLocalization.calendar(
            for: .simplifiedChinese,
            regionalCalendar: englishRegionalCalendar
        )
        let picker = NSDatePicker()

        LocalizedDatePickerConfiguration.apply(
            to: picker,
            locale: locale,
            calendar: calendar,
            isEnabled: true,
            accessibilityLabel: "manual date"
        )

        #expect(picker.locale?.identifier == "zh-Hans")
        #expect(picker.calendar?.identifier == .gregorian)
        #expect(picker.calendar?.locale?.identifier == "zh-Hans")
        #expect(picker.calendar?.monthSymbols[7] == "八月")
        #expect(picker.calendar?.veryShortWeekdaySymbols == ["日", "一", "二", "三", "四", "五", "六"])
        #expect(picker.calendar?.timeZone == englishRegionalCalendar.timeZone)
        #expect(picker.calendar?.firstWeekday == 2)
        #expect(picker.calendar?.minimumDaysInFirstWeek == 4)
        #expect(picker.datePickerStyle == .clockAndCalendar)
        #expect(picker.datePickerElements == [.yearMonthDay])
        #expect(!picker.presentsCalendarOverlay)
        #expect(picker.isEnabled)
        #expect(picker.accessibilityLabel() == "manual date")
    }

    @Test
    func nativePickerWritesChangedDateBackToSwiftUIBinding() {
        final class DateBox {
            var value = Date(timeIntervalSince1970: 1_700_000_000)
        }

        let box = DateBox()
        let coordinator = LocalizedDatePickerCoordinator(
            selection: Binding(
                get: { box.value },
                set: { box.value = $0 }
            )
        )
        let picker = NSDatePicker()
        let changedDate = Date(timeIntervalSince1970: 1_750_000_000)
        picker.dateValue = changedDate

        coordinator.dateChanged(picker)

        #expect(box.value == changedDate)
    }

    @Test
    func productionDateControlsUseTheLocalizedNativePicker() throws {
        let viewNames = [
            "LANInboxView.swift",
            "ImportReviewView.swift",
            "RecordEditView.swift",
            "DICOMStudyReviewView.swift",
        ]
        let bareDatePicker = try NSRegularExpression(pattern: #"(?<![A-Za-z])DatePicker\("#)

        for viewName in viewNames {
            let source = try String(
                contentsOf: viewsURL.appendingPathComponent(viewName),
                encoding: .utf8
            )
            #expect(source.contains("LocalizedDatePicker("), "Missing bridge in \(viewName)")
            #expect(
                bareDatePicker.firstMatch(
                    in: source,
                    range: NSRange(source.startIndex..., in: source)
                ) == nil,
                "Bare SwiftUI DatePicker remains in \(viewName)"
            )
        }
    }

    @Test
    func productionDateLabelsDoNotFallBackToSwiftUIOrSystemLocale() throws {
        let viewNames = [
            "ComparisonView.swift",
            "DICOMLibraryView.swift",
            "DICOMStudyViewer.swift",
            "ImportReviewView.swift",
            "RecordDetailView.swift",
            "RecordEditView.swift",
            "TimelineView.swift",
        ]

        for viewName in viewNames {
            let source = try String(
                contentsOf: viewsURL.appendingPathComponent(viewName),
                encoding: .utf8
            )
            #expect(
                !source.contains("@Environment(\\.locale)"),
                "SwiftUI locale can fall back inside a sheet in \(viewName)"
            )
            #expect(
                !source.contains("locale: .autoupdatingCurrent"),
                "System locale remains in \(viewName)"
            )
        }
    }

    private var viewsURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/KinlogueApp/Views")
    }
}
