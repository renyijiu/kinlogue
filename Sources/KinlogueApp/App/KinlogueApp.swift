import Darwin
import Dispatch
import KinlogueCore
import SwiftUI

@main
enum KinlogueApp {
    static func main() {
        switch AcceptanceSmokeEntry.current() {
        case .gui:
            KinlogueGUIApp.main()
        case .reject:
            Darwin.exit(64)
        case let .run(request):
            Task.detached(priority: .userInitiated) {
                switch await SyntheticAcceptanceRunner(request: request).run() {
                case let .exit(code):
                    Darwin.exit(code)
                case .holdForForcedTermination:
                    break
                }
            }
            dispatchMain()
        }
    }
}

private struct KinlogueGUIApp: App {
    /// Owns the library for the whole launch. Models exist only once the storage disclosure is
    /// accepted and the SQLite library has opened, so the scenes read them from here.
    @StateObject private var startup: LibraryLaunchCoordinator
    @AppStorage(AppLocalization.languagePreferenceKey)
    private var selectedLanguage = AppLanguage.system

    init() {
        _startup = StateObject(wrappedValue: LibraryLaunchCoordinator.makeDefault())
    }

    var body: some Scene {
        Window(
            AppLocalization.string("续页", language: selectedLanguage),
            id: "main"
        ) {
            SQLiteAppLaunchView(startup: startup, selectedLanguage: $selectedLanguage)
                .frame(minWidth: 920, minHeight: 620)
                .environment(\.locale, AppLocalization.locale(for: selectedLanguage))
                .environment(\.calendar, AppLocalization.calendar(for: selectedLanguage))
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button(AppLocalization.string("导入报告…")) {
                    NotificationCenter.default.post(name: .kinloguePresentImporter, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            CommandMenu(AppLocalization.string("查找")) {
                Button(AppLocalization.string("搜索")) {
                    NotificationCenter.default.post(name: .kinlogueFocusSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }

            CommandMenu(AppLocalization.string("记录")) {
                Button(AppLocalization.string("选择两条记录比较")) {
                    NotificationCenter.default.post(name: .kinlogueToggleComparison, object: nil)
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            }
        }

        WindowGroup(
            AppLocalization.string("二维医学影像查看器", language: selectedLanguage),
            id: DICOMViewerWindowScene.id,
            for: DICOMStudy.ID.self
        ) { $studyID in
            if let studyID, let model = startup.composition?.appModel {
                DICOMStudyViewerContainer(
                    model: model.makeDICOMStudyViewerModel(studyID: studyID)
                )
                .id(studyID)
                .environment(\.locale, AppLocalization.locale(for: selectedLanguage))
                .environment(\.calendar, AppLocalization.calendar(for: selectedLanguage))
            }
        }
        .defaultSize(width: 1_120, height: 820)
        .windowResizability(.contentMinSize)
    }
}

extension Notification.Name {
    static let kinloguePresentImporter = Notification.Name("com.kinlogue.command.import")
    static let kinlogueFocusSearch = Notification.Name("com.kinlogue.command.search")
    static let kinlogueToggleComparison = Notification.Name("com.kinlogue.command.compare")
}
