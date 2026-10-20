import KinlogueCore
import SwiftUI

/// Likely recognition misreadings in the table lines of an editable results transcription, each
/// with the reading the form almost certainly printed. Nothing changes until the user takes a
/// suggestion; a marker such as "↑" carries meaning, so none is put in on the user's behalf.
struct RecognitionSuggestionsPanel: View {
    @Binding var text: String
    /// Suggestions the user set aside while this editor is open.
    @State private var ignored: Set<RecognitionSuggestion> = []

    var body: some View {
        let suggestions = RecognitionSuggestion.suggestions(in: text).filter { !ignored.contains($0) }
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label(AppLocalization.string("可能的识别错误"), systemImage: "text.magnifyingglass")
                    .font(.subheadline.weight(.semibold))
                Text(AppLocalization.string("以下按常见的识别误读找出，采纳前请对照原件。"))
                    .font(.caption)
                    .foregroundStyle(KinlogueTheme.onVariant)
                ForEach(suggestions, id: \.self) { suggestion in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.item)
                                .font(.caption)
                                .foregroundStyle(KinlogueTheme.onVariant)
                                .lineLimit(1)
                            Text(AppLocalization.string("\(suggestion.before) → \(suggestion.after)"))
                                .font(.subheadline.monospacedDigit())
                                .lineLimit(2)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(AppLocalization.string("\(suggestion.item)：\(suggestion.before) 改为 \(suggestion.after)"))
                        Spacer(minLength: 8)
                        Button(AppLocalization.string("采纳")) {
                            if let fixed = suggestion.applied(to: text) { text = fixed }
                        }
                        .buttonStyle(.kinlogueGhost)
                        .accessibilityHint(AppLocalization.string("把检查结果里的这一格改成建议的写法"))
                        Button(AppLocalization.string("忽略")) {
                            ignored.insert(suggestion)
                        }
                        .buttonStyle(.kinlogueGhost(.neutral))
                        .accessibilityHint(AppLocalization.string("保留识别出的写法"))
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .kinloguePanel(.container, cornerRadius: KinlogueTheme.Radius.control)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(AppLocalization.string("可能的识别错误"))
        }
    }
}
