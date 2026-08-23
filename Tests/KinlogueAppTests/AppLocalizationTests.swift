import Foundation
import Testing

@testable import KinlogueApp

struct AppLocalizationTests {
    @Test
    func packagedAppDoesNotEvaluateTheSwiftPackageResourceBundle() {
        var packageBundleLookupCount = 0

        let selectedBundle = AppLocalization.resourceBundle(
            mainBundle: .main,
            mainBundleURL: URL(fileURLWithPath: "/Applications/Kinlogue.app"),
            packageBundle: {
                packageBundleLookupCount += 1
                return .main
            }
        )

        #expect(selectedBundle === Bundle.main)
        #expect(packageBundleLookupCount == 0)
    }

    @Test
    func commandLineTargetsUseTheSwiftPackageResourceBundle() {
        var packageBundleLookupCount = 0

        _ = AppLocalization.resourceBundle(
            mainBundle: .main,
            mainBundleURL: URL(fileURLWithPath: "/tmp/KinloguePackageTests.xctest"),
            packageBundle: {
                packageBundleLookupCount += 1
                return .main
            }
        )

        #expect(packageBundleLookupCount == 1)
    }

    @Test
    func languagePreferencePersistsOnlySupportedSelections() {
        let suiteName = "AppLocalizationTests.languagePreference"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(AppLocalization.selectedLanguage(in: defaults) == .system)

        defaults.set(AppLanguage.english.rawValue, forKey: AppLocalization.languagePreferenceKey)
        #expect(AppLocalization.selectedLanguage(in: defaults) == .english)

        defaults.set("fr", forKey: AppLocalization.languagePreferenceKey)
        #expect(AppLocalization.selectedLanguage(in: defaults) == .system)
    }

    @Test
    func explicitLanguageSelectionOverridesTheSystemPreference() {
        #expect(
            AppLocalization.languageIdentifier(
                for: .english,
                preferredLocalizations: ["zh-Hans"]
            ) == "en"
        )
        #expect(
            AppLocalization.languageIdentifier(
                for: .simplifiedChinese,
                preferredLocalizations: ["en"]
            ) == "zh-Hans"
        )
    }

    @Test
    func systemLanguageSelectionUsesSupportedPreferencesAndFallsBackToChinese() {
        #expect(
            AppLocalization.languageIdentifier(
                for: .system,
                preferredLocalizations: ["en-US", "zh-Hans"]
            ) == "en"
        )
        #expect(
            AppLocalization.languageIdentifier(
                for: .system,
                preferredLocalizations: ["fr"]
            ) == "zh-Hans"
        )
    }

    @Test
    func selectedLanguageProvidesLocalizedGregorianCalendarSymbols() {
        let chinese = AppLocalization.calendar(for: .simplifiedChinese)
        let english = AppLocalization.calendar(for: .english)

        #expect(chinese.identifier == .gregorian)
        #expect(chinese.monthSymbols[7] == "八月")
        #expect(chinese.veryShortWeekdaySymbols == ["日", "一", "二", "三", "四", "五", "六"])
        #expect(english.identifier == .gregorian)
        #expect(english.monthSymbols[7] == "August")
        #expect(english.veryShortWeekdaySymbols == ["S", "M", "T", "W", "T", "F", "S"])
    }

    @Test
    func settingsCopyResolvesForAnExplicitLanguageSelection() {
        #expect(
            AppLocalization.string(
                "设置",
                language: .simplifiedChinese
            ) == "设置"
        )
        #expect(
            AppLocalization.string(
                "设置",
                language: .english
            ) == "Settings"
        )
        #expect(
            AppLocalization.string(
                "删除本机数据…",
                language: .simplifiedChinese
            ) == "删除本机数据…"
        )
        #expect(
            AppLocalization.string(
                "删除本机数据…",
                language: .english
            ) == "Delete Local Data…"
        )
        #expect(
            AppLocalization.string(
                "彻底删除",
                language: .english
            ) == "Permanently Delete"
        )
        #expect(
            AppLocalization.string(
                "导出原始文件…",
                language: .english
            ) == "Export Originals…"
        )
        #expect(
            AppLocalization.string(
                "导出的压缩包包含未加密的健康资料",
                language: .english
            ) == "The exported ZIP contains unencrypted health information"
        )
        #expect(
            AppLocalization.string(
                "续页只能验证所选目录里的本地恢复点，无法证明网盘客户端已经上传。",
                language: .simplifiedChinese
            ) == "续页只能验证所选目录里的本地恢复点，无法证明网盘客户端已经上传。"
        )
        #expect(
            AppLocalization.string(
                "续页只能验证所选目录里的本地恢复点，无法证明网盘客户端已经上传。",
                language: .english
            ) == "Kinlogue can verify only the local restore point in the selected folder. It cannot prove that a cloud-drive client uploaded it."
        )
        #expect(
            AppLocalization.string(
                "确认替换本机资料库",
                language: .english
            ) == "Confirm Replace Local Library"
        )
    }

    @Test
    func exportProgressAndResultCopyPreserveTypedValuesInEnglish() {
        let completed = 1
        let total = 2
        let size = "10 MB"

        #expect(
            AppLocalization.string(
                "已处理 \(completed) / \(AppLocalization.string("\(total) 个文件", language: .english))",
                language: .english
            ) == "1 of 2 files processed"
        )
        #expect(
            AppLocalization.string(
                "共 \(total) 个文件，\(size)",
                language: .english
            ) == "2 files, 10 MB"
        )
        #expect(
            AppLocalization.string(
                "共 \(completed) 个文件，\(size)",
                language: .english
            ) == "1 file, 10 MB"
        )
    }

    @Test
    func dynamicToolbarHelpResolvesForBothSupportedLanguages() {
        #expect(
            AppLocalization.string(
                "查看手机接收状态",
                language: .simplifiedChinese
            ) == "查看手机接收状态"
        )
        #expect(
            AppLocalization.string(
                "查看手机接收状态",
                language: .english
            ) == "View Phone Receiving Status"
        )
    }

    @Test
    func recordConflictRecoveryCopyResolvesInEnglish() {
        #expect(
            AppLocalization.string(
                "重新载入最新版本",
                language: .english
            ) == "Reload Latest Version"
        )
        #expect(
            AppLocalization.string(
                "这条记录已在其他窗口中更新。重新载入最新版本会替换此页未保存的修改。",
                language: .english
            ) == "This record was updated in another window. Reloading the latest version will replace unsaved edits on this page."
        )
        #expect(
            AppLocalization.string(
                "这条记录已在其他窗口中发生变化，当前修改无法保存。请关闭编辑页。",
                language: .english
            ) == "This record changed in another window, so these edits cannot be saved. Close the editor."
        )
    }

    @Test
    func resolvesStaticStringsInBothSupportedLanguages() {
        #expect(
            AppLocalization.string(
                "取消",
                locale: Locale(identifier: "zh-Hans")
            ) == "取消"
        )
        #expect(
            AppLocalization.string(
                "取消",
                locale: Locale(identifier: "en")
            ) == "Cancel"
        )
    }

    @Test
    func localizesOriginalImageRotationControls() {
        #expect(AppLocalization.string(
            "向左旋转",
            locale: Locale(identifier: "zh-Hans")
        ) == "向左旋转")
        #expect(AppLocalization.string(
            "向左旋转",
            locale: Locale(identifier: "en")
        ) == "Rotate Left")
        #expect(AppLocalization.string(
            "向右旋转",
            locale: Locale(identifier: "zh-Hans")
        ) == "向右旋转")
        #expect(AppLocalization.string(
            "向右旋转",
            locale: Locale(identifier: "en")
        ) == "Rotate Right")
    }

    @Test
    func preservesTypedInterpolationAcrossLanguages() {
        let count = 2

        #expect(
            AppLocalization.string(
                "\(count) 个文件",
                locale: Locale(identifier: "zh-Hans")
            ) == "2 个文件"
        )
        #expect(
            AppLocalization.string(
                "\(count) 个文件",
                locale: Locale(identifier: "en")
            ) == "2 files"
        )
    }

    @Test
    func localizesDICOMSeriesAndPlaybackCountsInBothLanguages() {
        #expect(
            AppLocalization.string(
                "序列 \(3)，\(184) 张",
                locale: Locale(identifier: "zh-Hans")
            ) == "序列 3，184 张"
        )
        #expect(
            AppLocalization.string(
                "序列 \(3)，\(184) 张",
                locale: Locale(identifier: "en")
            ) == "Series 3, 184 slices"
        )
        #expect(
            AppLocalization.string(
                "共 \(14) 个序列，\(400) 张可查看影像",
                locale: Locale(identifier: "zh-Hans")
            ) == "共 14 个序列，400 张可查看影像"
        )
        #expect(
            AppLocalization.string(
                "共 \(14) 个序列，\(400) 张可查看影像",
                locale: Locale(identifier: "en")
            ) == "14 series · 400 viewable slices"
        )
        #expect(
            AppLocalization.string(
                "每秒 \(10) 张",
                locale: Locale(identifier: "zh-Hans")
            ) == "每秒 10 张"
        )
        #expect(
            AppLocalization.string(
                "每秒 \(10) 张",
                locale: Locale(identifier: "en")
            ) == "10 slices per second"
        )
    }

    @Test
    func fallsBackToTheChineseSourceLanguageForUnsupportedLocales() {
        #expect(
            AppLocalization.string(
                "取消",
                locale: Locale(identifier: "fr")
            ) == "取消"
        )
    }

    @Test
    func localizesPendingQueueSummaryInBothLanguages() {
        let itemCount = 2
        let size = "1 MB"

        #expect(
            AppLocalization.string(
                "\(itemCount) 个唯一原件 · 实际占用 \(size)",
                locale: Locale(identifier: "zh-Hans")
            ) == "2 个唯一原件 · 实际占用 1 MB"
        )
        #expect(
            AppLocalization.string(
                "\(itemCount) 个唯一原件 · 实际占用 \(size)",
                locale: Locale(identifier: "en")
            ) == "Unique originals: 2 · Disk usage: 1 MB"
        )
        #expect(
            AppLocalization.string(
                "\(1) 个唯一原件 · 实际占用 \(size)",
                locale: Locale(identifier: "en")
            ) == "Unique original: 1 · Disk usage: 1 MB"
        )
    }

    @Test
    func localizesPendingItemStateInBothLanguages() {
        #expect(
            AppLocalization.string(
                "可选择并归档",
                locale: Locale(identifier: "zh-Hans")
            ) == "可选择并归档"
        )
        #expect(
            AppLocalization.string(
                "可选择并归档",
                locale: Locale(identifier: "en")
            ) == "Ready to select and archive"
        )
    }

    @Test
    func localizesPendingItemActionsWithoutChangingTheDisplayName() {
        let displayName = "sample.pdf"

        #expect(
            AppLocalization.string(
                "删除待确认项 \(displayName)",
                locale: Locale(identifier: "zh-Hans")
            ) == "删除待确认项 sample.pdf"
        )
        #expect(
            AppLocalization.string(
                "删除待确认项 \(displayName)",
                locale: Locale(identifier: "en")
            ) == "Delete pending item sample.pdf"
        )
        #expect(
            AppLocalization.string(
                "将 \(displayName) 向前移动",
                locale: Locale(identifier: "zh-Hans")
            ) == "将 sample.pdf 向前移动"
        )
        #expect(
            AppLocalization.string(
                "将 \(displayName) 向前移动",
                locale: Locale(identifier: "en")
            ) == "Move sample.pdf forward"
        )
        #expect(
            AppLocalization.string(
                "将 \(displayName) 向后移动",
                locale: Locale(identifier: "zh-Hans")
            ) == "将 sample.pdf 向后移动"
        )
        #expect(
            AppLocalization.string(
                "将 \(displayName) 向后移动",
                locale: Locale(identifier: "en")
            ) == "Move sample.pdf backward"
        )
    }

    @Test
    func localizesPendingSelectionCountsInBothLanguages() {
        let itemCount = 3
        let position = 2

        #expect(
            AppLocalization.string(
                "共 \(itemCount) 个原件；顺序只影响这次报告。",
                locale: Locale(identifier: "zh-Hans")
            ) == "共 3 个原件；顺序只影响这次报告。"
        )
        #expect(
            AppLocalization.string(
                "共 \(itemCount) 个原件；顺序只影响这次报告。",
                locale: Locale(identifier: "en")
            ) == "3 originals; the order only affects this report."
        )
        #expect(
            AppLocalization.string(
                "查看第 \(position) 个原件",
                locale: Locale(identifier: "zh-Hans")
            ) == "查看第 2 个原件"
        )
        #expect(
            AppLocalization.string(
                "查看第 \(position) 个原件",
                locale: Locale(identifier: "en")
            ) == "View original 2"
        )
        #expect(
            AppLocalization.string(
                "已选 \(itemCount) 个原件，作为 1 份报告",
                locale: Locale(identifier: "zh-Hans")
            ) == "已选 3 个原件，作为 1 份报告"
        )
        #expect(
            AppLocalization.string(
                "已选 \(itemCount) 个原件，作为 1 份报告",
                locale: Locale(identifier: "en")
            ) == "3 originals selected as one report"
        )
        #expect(
            AppLocalization.string(
                "共 \(1) 个原件；顺序只影响这次报告。",
                locale: Locale(identifier: "en")
            ) == "1 original; the order only affects this report."
        )
        #expect(
            AppLocalization.string(
                "已选 \(1) 个原件，作为 1 份报告",
                locale: Locale(identifier: "en")
            ) == "1 original selected as one report"
        )
    }
}

struct LocalizationPackagingTests {
    private static let swiftStringLiteralExpression = try! NSRegularExpression(
        pattern: ##"(#*)("""|")(.*?)(?:\2\1)"##,
        options: [.dotMatchesLineSeparators]
    )

    @Test
    func hardcodingScannerRejectsMixedMultilineAndRawChineseLiterals() {
        let source = [
            #"Text("裸文案").accessibilityLabel(AppLocalization.string("已本地化"))"#,
            "Text(\"\"\"",
            "多行裸文案",
            "\"\"\")",
            "Text(#\"原始裸文案\"#)",
        ].joined(separator: "\n")

        #expect(
            bareChineseLocalizedLiteralLines(
                in: source,
                fileName: "ExampleView.swift"
            ) == [1, 2, 5]
        )
        #expect(
            bareChineseLocalizedLiteralLines(
                in: #"Text("简体中文")"#,
                fileName: "SettingsView.swift"
            ).isEmpty
        )
    }

    @Test
    func appSwiftSourcesDoNotIntroduceBareChineseUserFacingLiterals() throws {
        let sourceRoot = repositoryURL.appendingPathComponent("Sources/KinlogueApp")
        let sourceURLs = try #require(
            FileManager.default.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: [.isRegularFileKey]
            )?.allObjects as? [URL]
        )
        var violations: [String] = []

        for sourceURL in sourceURLs where sourceURL.pathExtension == "swift" {
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            for lineNumber in bareChineseLocalizedLiteralLines(
                in: source,
                fileName: sourceURL.lastPathComponent
            ) {
                violations.append(
                    "\(sourceURL.path.replacingOccurrences(of: repositoryURL.path + "/", with: "")):\(lineNumber)"
                )
            }
        }

        #expect(
            violations.isEmpty,
            "Chinese-localized literals must use AppLocalization.string: \(violations.joined(separator: ", "))"
        )
    }

    private func bareChineseLocalizedLiteralLines(
        in source: String,
        fileName: String
    ) -> [Int] {
        let sourceRange = NSRange(source.startIndex..., in: source)

        return Self.swiftStringLiteralExpression.matches(
            in: source,
            range: sourceRange
        ).compactMap { match in
            guard let literalRange = Range(match.range, in: source) else { return nil }
            let literal = source[literalRange]
            let containsHan = literal.unicodeScalars.contains { scalar in
                (0x3400...0x4DBF).contains(scalar.value)
                    || (0x4E00...0x9FFF).contains(scalar.value)
                    || (0xF900...0xFAFF).contains(scalar.value)
                    || (0x20000...0x2CEAF).contains(scalar.value)
            }
            let containsLocalizedPunctuation = literal.contains { character in
                "，。；：？！、".contains(character)
            }
            guard containsHan || containsLocalizedPunctuation else { return nil }

            let lineStart = source[..<literalRange.lowerBound].lastIndex(of: "\n")
                .map { source.index(after: $0) } ?? source.startIndex
            let linePrefix = source[lineStart..<literalRange.lowerBound]
            let trimmedPrefix = linePrefix.trimmingCharacters(in: .whitespaces)
            guard !trimmedPrefix.hasPrefix("//"),
                  !trimmedPrefix.hasPrefix("*"),
                  !trimmedPrefix.hasSuffix("AppLocalization.string(") else {
                return nil
            }
            if fileName == "SettingsView.swift", literal == #""简体中文""# {
                return nil
            }

            return source[..<literalRange.lowerBound].reduce(into: 1) { line, character in
                if character == "\n" { line += 1 }
            }
        }
    }

    @Test
    func catalogHasAnEnglishTranslationForEverySourceString() throws {
        let catalogData = try Data(
            contentsOf: repositoryURL.appendingPathComponent(
                "Sources/KinlogueApp/Localization/Localizable.xcstrings"
            )
        )
        let catalog = try #require(
            JSONSerialization.jsonObject(with: catalogData) as? [String: Any]
        )
        #expect(catalog["sourceLanguage"] as? String == "zh-Hans")
        let strings = try #require(catalog["strings"] as? [String: Any])
        #expect(!strings.isEmpty)

        for (key, rawEntry) in strings {
            let entry = try #require(rawEntry as? [String: Any], "Invalid catalog entry: \(key)")
            let localizations = try #require(
                entry["localizations"] as? [String: Any],
                "Missing localizations: \(key)"
            )
            #expect(
                localizations["en"] != nil,
                "Missing English translation: \(key)"
            )
            let englishValues = localizedStringUnitValues(
                in: try #require(
                    localizations["en"],
                    "Missing English translation: \(key)"
                )
            )
            #expect(
                !englishValues.isEmpty
                    && englishValues.allSatisfy {
                        !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    },
                "Empty English translation: \(key)"
            )
            #expect(
                Set(localizations.keys).isSubset(of: ["zh-Hans", "en"]),
                "Unexpected localization: \(key)"
            )
        }
    }

    @Test
    func appBundleDeclaresOnlyEnglishAndSimplifiedChinese() throws {
        let infoPlist = try Data(contentsOf: repositoryURL.appendingPathComponent("packaging/Info.plist"))
        let object = try #require(
            PropertyListSerialization.propertyList(from: infoPlist, format: nil)
                as? [String: Any]
        )

        #expect(object["CFBundleDevelopmentRegion"] as? String == "zh-Hans")
        #expect(
            object["CFBundleLocalizations"] as? [String] == ["zh-Hans", "en"]
        )
    }

    @Test
    func releaseBuilderCopiesAppLocalizationsIntoTheMainBundle() throws {
        let buildScript = try String(
            contentsOf: repositoryURL.appendingPathComponent("scripts/build-app.sh"),
            encoding: .utf8
        )

        #expect(buildScript.contains("Kinlogue_KinlogueApp.bundle"))
        #expect(buildScript.contains("en.lproj"))
        #expect(buildScript.contains("zh-hans.lproj"))
    }

    @Test
    func runtimeLanguageSelectionUsesTheAppPreferenceInsteadOfTheRegionLocale() throws {
        let source = try String(
            contentsOf: repositoryURL.appendingPathComponent(
                "Sources/KinlogueApp/App/AppLocalization.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains("Bundle.main.preferredLocalizations"))
        #expect(!source.contains("Locale.current"))
    }

    @Test
    func guiInjectsTheSelectedLanguageCalendarIntoTheSwiftUIEnvironment() throws {
        let source = try String(
            contentsOf: repositoryURL.appendingPathComponent(
                "Sources/KinlogueApp/App/KinlogueApp.swift"
            ),
            encoding: .utf8
        )

        #expect(
            source.contains(
                ".environment(\\.calendar, AppLocalization.calendar(for: selectedLanguage))"
            )
        )
    }

    private var repositoryURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func localizedStringUnitValues(in rawValue: Any) -> [String] {
        if let dictionary = rawValue as? [String: Any] {
            if let stringUnit = dictionary["stringUnit"] as? [String: Any],
               let value = stringUnit["value"] as? String {
                return [value]
            }
            return dictionary.values.flatMap(localizedStringUnitValues)
        }
        if let array = rawValue as? [Any] {
            return array.flatMap(localizedStringUnitValues)
        }
        return []
    }

}
