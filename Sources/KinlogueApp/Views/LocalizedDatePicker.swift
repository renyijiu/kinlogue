import AppKit
import SwiftUI

struct LocalizedDatePicker: View {
    let label: String
    let language: AppLanguage
    @Binding var selection: Date
    @State private var isCalendarPresented = false

    init(
        _ label: String,
        selection: Binding<Date>,
        language: AppLanguage = AppLocalization.selectedLanguage()
    ) {
        self.label = label
        self.language = language
        _selection = selection
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .accessibilityHidden(true)
            Button {
                isCalendarPresented.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text(formattedSelection)
                    Image(systemName: "calendar")
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel(label)
            .accessibilityValue(formattedSelection)
            .popover(isPresented: $isCalendarPresented, arrowEdge: .bottom) {
                LocalizedDatePickerControl(
                    accessibilityLabel: label,
                    language: language,
                    selection: $selection,
                    onSelection: { isCalendarPresented = false }
                )
                .fixedSize()
                .padding(12)
            }
        }
    }

    private var formattedSelection: String {
        let calendar = AppLocalization.calendar(for: language)
        return selection.formatted(Date.FormatStyle(
            date: .numeric,
            time: .omitted,
            locale: AppLocalization.locale(for: language),
            calendar: calendar,
            timeZone: calendar.timeZone
        ))
    }
}

private struct LocalizedDatePickerControl: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled

    let accessibilityLabel: String
    let language: AppLanguage
    @Binding var selection: Date
    let onSelection: () -> Void

    func makeCoordinator() -> LocalizedDatePickerCoordinator {
        LocalizedDatePickerCoordinator(
            selection: $selection,
            onSelection: onSelection
        )
    }

    func makeNSView(context: Context) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.target = context.coordinator
        picker.action = #selector(LocalizedDatePickerCoordinator.dateChanged(_:))
        picker.setContentHuggingPriority(.required, for: .horizontal)
        picker.setContentCompressionResistancePriority(.required, for: .horizontal)
        update(picker, coordinator: context.coordinator)
        return picker
    }

    func updateNSView(_ picker: NSDatePicker, context: Context) {
        update(picker, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ picker: NSDatePicker, coordinator: LocalizedDatePickerCoordinator) {
        picker.target = nil
        picker.action = nil
    }

    private func update(
        _ picker: NSDatePicker,
        coordinator: LocalizedDatePickerCoordinator
    ) {
        coordinator.selection = $selection
        coordinator.onSelection = onSelection
        let calendar = AppLocalization.calendar(for: language)
        LocalizedDatePickerConfiguration.apply(
            to: picker,
            locale: AppLocalization.locale(for: language),
            calendar: calendar,
            isEnabled: isEnabled,
            accessibilityLabel: accessibilityLabel
        )
        if picker.dateValue != selection {
            picker.dateValue = selection
        }
    }
}

@MainActor
enum LocalizedDatePickerConfiguration {
    static func apply(
        to picker: NSDatePicker,
        locale: Locale,
        calendar: Calendar,
        isEnabled: Bool,
        accessibilityLabel: String
    ) {
        var localizedCalendar = calendar
        localizedCalendar.locale = locale

        picker.datePickerStyle = .clockAndCalendar
        picker.datePickerElements = [.yearMonthDay]
        picker.presentsCalendarOverlay = false
        picker.locale = locale
        picker.calendar = localizedCalendar
        picker.timeZone = localizedCalendar.timeZone
        picker.isEnabled = isEnabled
        picker.setAccessibilityLabel(accessibilityLabel)
    }
}

@MainActor
final class LocalizedDatePickerCoordinator: NSObject {
    var selection: Binding<Date>
    var onSelection: () -> Void

    init(
        selection: Binding<Date>,
        onSelection: @escaping () -> Void = {}
    ) {
        self.selection = selection
        self.onSelection = onSelection
    }

    @objc
    func dateChanged(_ sender: NSDatePicker) {
        selection.wrappedValue = sender.dateValue
        onSelection()
    }
}
