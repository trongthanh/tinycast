import SwiftUI

struct DictionarySuggestionsView: View {
    @Environment(\.metrics) private var metrics
    let suggestions: [DictionaryLookup.Suggestion]
    let selectedTerm: String?
    let scroll: ScrollIntent
    let onActivate: (String) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    SectionHeader(title: "Did you mean?", isFirst: true)
                    ForEach(suggestions) { suggestion in
                        SuggestionRow(suggestion: suggestion, selected: suggestion.term == selectedTerm)
                            .selectionFrame(suggestion.term == selectedTerm)
                            .contentShape(Rectangle())
                            .onTapGesture { onActivate(suggestion.term) }
                    }
                }
                .padding(.horizontal, metrics.spacing.md)
                .padding(.top, metrics.spacing.xs)
                .padding(.bottom, metrics.spacing.md)
                .hideNativeScrollers()
                .scrollOriginAnchor()
            }
            .edgeDissolve()
            .thinScrollbar()
            .scrollFollowsSelection(
                scroll, row: selectedTerm, atOrigin: selectedTerm == suggestions.first?.term, proxy: proxy)
        }
    }

    private struct SuggestionRow: View {
        @Environment(\.metrics) private var metrics
        let suggestion: DictionaryLookup.Suggestion
        let selected: Bool
        @State private var hovered = false

        private var fill: Color {
            if selected { return Theme.Colors.selection }
            if hovered { return Theme.Colors.rowHover }
            return .clear
        }

        var body: some View {
            HStack(spacing: metrics.spacing.lg) {
                Text(suggestion.term)
                    .font(metrics.typography.rowTitle.weight(.medium))
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(suggestion.preview)
                    .font(metrics.typography.rowTitle)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, metrics.spacing.md)
            .padding(.vertical, metrics.spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: metrics.radius.row, style: .continuous).fill(fill))
            .armedHover($hovered)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Show details for \(suggestion.term)")
            .accessibilityValue(suggestion.preview)
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
}
