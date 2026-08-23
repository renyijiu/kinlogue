import SwiftUI

struct SearchFieldView: View {
    @Binding var text: String
    let isFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(AppLocalization.string("搜索已确认的成员、日期、医院或结论"), text: $text)
                .textFieldStyle(.plain)
                .focused(isFocused)
                .accessibilityLabel(AppLocalization.string("搜索已确认的记录"))
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppLocalization.string("清除搜索"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(KinlogueTheme.container, in: Capsule())
        .overlay(Capsule().stroke(KinlogueTheme.outline))
        .padding(16)
    }
}
