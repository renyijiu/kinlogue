import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    var localizationIdentifier: String? {
        self == .system ? nil : rawValue
    }
}

enum AppLocalization {
    static let supportedLanguageIdentifiers = AppLanguage.allCases.compactMap(\.localizationIdentifier)
    static let languagePreferenceKey = "KinlogueAppLanguage"

    static func string(
        _ keyAndValue: String.LocalizationValue,
        comment: StaticString? = nil
    ) -> String {
        string(
            keyAndValue,
            language: selectedLanguage(),
            comment: comment
        )
    }

    static func string(
        _ keyAndValue: String.LocalizationValue,
        language: AppLanguage,
        comment: StaticString? = nil
    ) -> String {
        let localization = localization(for: language)
        return String(
            localized: keyAndValue,
            bundle: localization.bundle,
            locale: localization.locale,
            comment: comment
        )
    }

    static func string(
        _ keyAndValue: String.LocalizationValue,
        locale: Locale,
        comment: StaticString? = nil
    ) -> String {
        String(
            localized: keyAndValue,
            bundle: localizedBundle(for: locale),
            locale: locale,
            comment: comment
        )
    }

    static func selectedLanguage(in userDefaults: UserDefaults = .standard) -> AppLanguage {
        guard let rawValue = userDefaults.string(forKey: languagePreferenceKey),
              let language = AppLanguage(rawValue: rawValue) else {
            return .system
        }
        return language
    }

    static func locale(for language: AppLanguage) -> Locale {
        localization(for: language).locale
    }

    static func calendar(
        for language: AppLanguage,
        regionalCalendar: Calendar = .autoupdatingCurrent
    ) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale(for: language)
        calendar.timeZone = regionalCalendar.timeZone
        calendar.firstWeekday = regionalCalendar.firstWeekday
        calendar.minimumDaysInFirstWeek = regionalCalendar.minimumDaysInFirstWeek
        return calendar
    }

    static func languageIdentifier(
        for language: AppLanguage,
        preferredLocalizations: [String]
    ) -> String {
        if let identifier = language.localizationIdentifier {
            return identifier
        }
        return preferredLocalizations.lazy.compactMap {
            matchedLanguageIdentifier(for: Locale(identifier: $0))
        }.first ?? fallbackLanguage.rawValue
    }

    static func resourceBundle(
        mainBundle: Bundle,
        mainBundleURL: URL,
        packageBundle: () -> Bundle
    ) -> Bundle {
        if mainBundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
            return mainBundle
        }
        return packageBundle()
    }

    private static func localizedBundle(for locale: Locale) -> Bundle {
        let languageIdentifier = matchedLanguageIdentifier(for: locale) ?? fallbackLanguage.rawValue
        return localizedBundles[languageIdentifier] ?? runtimeResourceBundle
    }

    private struct Localization {
        let locale: Locale
        let bundle: Bundle
    }

    private static func localization(for language: AppLanguage) -> Localization {
        localizations[language] ?? localizations[.system]!
    }

    private static let localizations = Dictionary(
        uniqueKeysWithValues: AppLanguage.allCases.map { language in
            let locale = Locale(
                identifier: languageIdentifier(
                    for: language,
                    preferredLocalizations: systemPreferredLocalizations
                )
            )
            return (
                language,
                Localization(locale: locale, bundle: localizedBundle(for: locale))
            )
        }
    )

    private static let localizedBundles = Dictionary(
        uniqueKeysWithValues: supportedLanguageIdentifiers.map { languageIdentifier in
            let bundle = localizedBundle(
                in: .main,
                languageIdentifier: languageIdentifier
            ) ?? localizedBundle(
                in: runtimeResourceBundle,
                languageIdentifier: languageIdentifier
            ) ?? runtimeResourceBundle
            return (languageIdentifier, bundle)
        }
    )

    private static let runtimeResourceBundle = resourceBundle(
        mainBundle: .main,
        mainBundleURL: Bundle.main.bundleURL,
        packageBundle: { .module }
    )
    private static let systemPreferredLocalizations =
        Bundle.main.preferredLocalizations + runtimeResourceBundle.preferredLocalizations
    private static let fallbackLanguage = AppLanguage.simplifiedChinese

    private static func matchedLanguageIdentifier(for locale: Locale) -> String? {
        switch locale.language.languageCode?.identifier {
        case "en": "en"
        case "zh": "zh-Hans"
        default: nil
        }
    }

    private static func localizedBundle(
        in container: Bundle,
        languageIdentifier: String
    ) -> Bundle? {
        guard let resourceURL = container.url(
            forResource: "Localizable",
            withExtension: "strings",
            subdirectory: nil,
            localization: languageIdentifier
        ), let bundle = Bundle(url: resourceURL.deletingLastPathComponent()) else {
            return nil
        }
        return bundle
    }
}
