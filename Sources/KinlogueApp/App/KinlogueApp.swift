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
    @StateObject private var model: AppModel
    @StateObject private var deletionModel: VaultDeletionModel
    @StateObject private var lanInboxModel: LANInboxModel
    @StateObject private var backupModel: BackupModel
    @StateObject private var restoreModel: RestoreModel
    private let startupCoordinator: AppStartupCoordinator
    @AppStorage(AppLocalization.languagePreferenceKey)
    private var selectedLanguage = AppLanguage.system

    init() {
        let composition = AppComposition.makeDefault()
        _model = StateObject(wrappedValue: composition.appModel)
        _deletionModel = StateObject(wrappedValue: composition.deletionModel)
        _lanInboxModel = StateObject(wrappedValue: composition.lanInboxModel)
        _backupModel = StateObject(wrappedValue: composition.backupModel)
        _restoreModel = StateObject(wrappedValue: composition.restoreModel)
        startupCoordinator = composition.startupCoordinator
    }

    var body: some Scene {
        Window(
            AppLocalization.string("续页", language: selectedLanguage),
            id: "main"
        ) {
            AppShellView(
                model: model,
                deletionModel: deletionModel,
                lanInboxModel: lanInboxModel,
                backupModel: backupModel,
                restoreModel: restoreModel,
                startupCoordinator: startupCoordinator,
                selectedLanguage: $selectedLanguage
            )
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
            if let studyID {
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
