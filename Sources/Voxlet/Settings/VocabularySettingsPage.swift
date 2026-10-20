import AppKit
import SwiftUI

struct VocabularySettingsPage: View {
    @ObservedObject private var store = VocabularyStore.shared
    @State private var draft = ""
    @State private var feedback: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(
                title: L10n.t("Vocabulary"),
                subtitle: L10n.t("Sent to Gemini with every dictation to get names, products and jargon right. Select a word anywhere and press the dictation shortcut to add it.")
            ) {
                HStack(spacing: 8) {
                    SettingsTextField(placeholder: L10n.t("Add a term, e.g. a name or product"), text: $draft)
                        .onSubmit(addDraft)
                    Button(L10n.t("Add"), action: addDraft)
                        .buttonStyle(SettingsCompactButtonStyle(prominent: true))
                        .disabled(draft.trimmed.isEmpty)
                }
                if let feedback {
                    Text(feedback)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }

                if store.terms.isEmpty {
                    Text(L10n.t("No terms yet."))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    FlowLayout(spacing: 6) {
                        ForEach(store.terms, id: \.self) { term in
                            TermChip(term: term) { store.remove(term) }
                        }
                    }
                }
            }

            SettingsCard(
                title: L10n.t("Vocabulary File"),
                subtitle: L10n.t("Plain text, one term per line; lines starting with # are ignored. Changes made in any editor apply right away.")
            ) {
                HStack(spacing: 8) {
                    Text(store.fileURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(L10n.t("Open in Editor")) { NSWorkspace.shared.open(store.fileURL) }
                        .buttonStyle(SettingsCompactButtonStyle())
                    Button(L10n.t("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([store.fileURL]) }
                        .buttonStyle(SettingsCompactButtonStyle())
                }
                Text(L10n.format("%d terms", store.terms.count))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { store.reload() }
    }

    private func addDraft() {
        switch store.add(draft) {
        case .added:
            draft = ""
            feedback = nil
        case .duplicate(let term):
            feedback = L10n.format("Already in vocabulary: %@", term)
        case .invalid:
            feedback = L10n.format("A term is one line of at most %d characters, with at least one letter or digit.", VocabularyStore.maxTermLength)
        }
    }
}

private struct TermChip: View {
    let term: String
    let onDelete: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(term)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(isHovering ? Color.primary.opacity(0.7) : Color.secondary.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help(L10n.t("Remove"))
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 26)
        .background(
            Capsule(style: .continuous)
                .fill(isHovering ? SettingsStyle.sidebarItemPressed : SettingsStyle.controlFill)
        )
        .onHover { isHovering = $0 }
    }
}

/// Lays children out left to right and wraps to a new line when the row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > maxWidth, !rows[rows.count - 1].indices.isEmpty {
                let previous = rows[rows.count - 1]
                rows.append(Row(y: previous.y + previous.height + spacing))
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}
