import KinlogueCore
import SwiftUI

struct ComparisonOriginalPane: View {
    let sideName: String
    let sources: ReportSources
    let selectedSourceID: ReportSource.ID?
    let payload: OriginalDocumentPayload?
    let loadState: ComparisonOriginalLoadState
    let onSelectSource: (ReportSource.ID) -> Void

    var body: some View {
        OrderedOriginalDocumentView(
            sources: sources,
            selectedSourceID: selectedSourceID,
            payload: payload,
            isLoading: loadState == .loading,
            onSelectSource: onSelectSource,
            presentation: .inline(onOpenOriginal: nil)
        )
        .accessibilityLabel(AppLocalization.string("\(sideName)原件，仅在应用内存中查看"))
    }
}
