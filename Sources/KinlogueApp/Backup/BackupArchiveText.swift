import Foundation
import KinlogueCore
import KinloguePlatform

/// The people-facing parts of a backup archive, in the App's current language. Restoring
/// reads none of them, so a backup made in one language restores in the other.
enum BackupArchiveText {
    static func content() -> BackupArchiveContent {
        let pending = AppLocalization.string("待确认")
        let phone = AppLocalization.string("手机待整理")
        let other = AppLocalization.string("其他")
        let info = Bundle.main.infoDictionary ?? [:]
        let creator = (try? BackupArchiveIndex.Creator(
            app: "Kinlogue",
            version: info["CFBundleShortVersionString"] as? String ?? "",
            build: info["CFBundleVersion"] as? String ?? ""
        )) ?? (try! BackupArchiveIndex.Creator(app: "Kinlogue", version: "", build: ""))
        return BackupArchiveContent(
            labels: BackupArchiveLabels(
                undated: AppLocalization.string("未注明日期"),
                pendingFolder: pending,
                phoneFolder: phone,
                otherFolder: other
            ),
            creator: creator,
            readmeFileName: AppLocalization.string("说明.txt"),
            readmeText: AppLocalization.string("""
            续页备份

            这个压缩包是续页资料库的完整备份，没有加密。任何拿到它的人都能看到其中全部家庭成员、报告、识别文字和原始文件。

            files 文件夹按家庭成员和日期存放原始文件，可以直接打开、打印，或把某位成员的文件夹发给医生。名称以“_\(pending)”“_\(phone)”“_\(other)”开头的文件夹里是尚未整理的原件。

            kinlogue-backup.json 和 data 文件夹用于恢复，请不要修改。恢复时在续页的“设置 → 数据备份与导出”中选择“从备份恢复…”，再选中这个压缩包；恢复会替换当前资料库。
            """) + "\n"
        )
    }

    /// `续页备份 2026-10-19 153012` in local time; the folder adds ` (2)` on a clash.
    static func fileNameStem(_ date: Date) -> String {
        let stamp = date.formatted(
            Date.VerbatimFormatStyle(
                format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)",
                timeZone: .current,
                calendar: Calendar(identifier: .gregorian)
            )
        )
        return AppLocalization.string("续页备份 \(stamp)")
    }
}
