import SwiftUI
import LonghandKit

/// The summary at the top of a transcript, on both shells. Shows what the
/// model wrote, says when the transcript has changed since, and offers the
/// actions: write one, write it again, edit, remove.
///
/// Honesty rules apply as they do to the transcript: the card names the
/// author (Apple's on-device model, or "edited"), and a summary of an older
/// version of the text is labelled rather than quietly shown as current.
public struct SummaryCard: View {
    public let summary: TranscriptSummary?
    public let isStale: Bool
    public let isWorking: Bool
    /// Why a summary cannot be written here, from `TranscriptSummarizer`.
    public let unavailableReason: String?
    /// The last attempt's failure, shown until the next attempt.
    public let errorText: String?
    public let onGenerate: () -> Void
    public let onEdit: () -> Void
    public let onCopy: () -> Void
    public let onDelete: () -> Void

    @State private var showRegenerateConfirm = false

    public init(summary: TranscriptSummary?, isStale: Bool, isWorking: Bool,
                unavailableReason: String?, errorText: String? = nil,
                onGenerate: @escaping () -> Void, onEdit: @escaping () -> Void,
                onCopy: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.summary = summary
        self.isStale = isStale
        self.isWorking = isWorking
        self.unavailableReason = unavailableReason
        self.errorText = errorText
        self.onGenerate = onGenerate
        self.onEdit = onEdit
        self.onCopy = onCopy
        self.onDelete = onDelete
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Summary", systemImage: "text.alignleft")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if isWorking {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Summarizing…").font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("summary-working")
                } else if summary != nil {
                    Menu {
                        Button(action: onEdit) { Label("Edit…", systemImage: "pencil") }
                        Button(action: onCopy) { Label("Copy Summary", systemImage: "doc.on.doc") }
                        if unavailableReason == nil {
                            Button {
                                if summary?.isEdited == true {
                                    showRegenerateConfirm = true
                                } else {
                                    onGenerate()
                                }
                            } label: {
                                Label("Summarize Again", systemImage: "arrow.clockwise")
                            }
                        }
                        Divider()
                        Button(role: .destructive, action: onDelete) {
                            Label("Remove Summary", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.body)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("Summary actions")
                    .accessibilityIdentifier("summary-menu")
                }
            }
            if let summary {
                SummaryBody(summary: summary)
                HStack(spacing: 4) {
                    Image(systemName: summary.isEdited ? "pencil" : "sparkles")
                    Text(attribution(summary))
                    if isStale {
                        Text("· Transcript changed since")
                    }
                }
                .font(.caption2)
                .foregroundStyle(isStale ? .orange : .secondary)
                .accessibilityIdentifier(isStale ? "summary-stale" : "summary-attribution")
            } else if !isWorking {
                if let unavailableReason {
                    Text(unavailableReason)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("summary-unavailable")
                } else {
                    Button(action: onGenerate) {
                        Label("Summarize This Recording", systemImage: "sparkles")
                            .font(.footnote.weight(.medium))
                    }
                    .accessibilityIdentifier("summary-generate")
                    Text("Written by Apple's on-device model. Nothing leaves this device.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let errorText, !isWorking {
                Label(errorText, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("summary-error")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("summary-card")
        .confirmationDialog("Replace your edited summary?",
                            isPresented: $showRegenerateConfirm,
                            titleVisibility: .visible) {
            Button("Summarize Again", role: .destructive, action: onGenerate)
            Button("Keep My Edits", role: .cancel) {}
        } message: {
            Text("You changed this summary by hand. Writing a new one throws those changes away.")
        }
    }

    private func attribution(_ summary: TranscriptSummary) -> String {
        if let editedAt = summary.editedAt {
            return "Edited \(editedAt.formatted(date: .abbreviated, time: .shortened))"
        }
        return "Apple on-device model · \(summary.generatedAt.formatted(date: .abbreviated, time: .shortened))"
    }
}

/// The summary's text, direction set per paragraph the way turns are.
struct SummaryBody: View {
    let summary: TranscriptSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !summary.overview.isEmpty {
                Text(summary.overview)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .environment(\.layoutDirection, direction(summary.overview))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            list("Key points", TranscriptSummary.cleaned(summary.keyPoints))
            list("Decisions", TranscriptSummary.cleaned(summary.decisions))
            list("Action items", TranscriptSummary.cleaned(summary.actionItems))
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private func list(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        Text(item).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.callout)
                    .environment(\.layoutDirection, direction(item))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func direction(_ text: String) -> LayoutDirection {
        BidiText.baseDirection(of: text) == .rtl ? .rightToLeft : .leftToRight
    }
}

/// The editor as a sheet on a transcript screen, kept out of the screen's own
/// modifier chain, which the type-checker already struggles with on the Mac.
public struct SummaryEditorPresentation: ViewModifier {
    @Binding var isPresented: Bool
    let summary: TranscriptSummary?
    let onSave: (TranscriptSummary) -> Void

    public init(isPresented: Binding<Bool>, summary: TranscriptSummary?,
                onSave: @escaping (TranscriptSummary) -> Void) {
        _isPresented = isPresented
        self.summary = summary
        self.onSave = onSave
    }

    public func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            if let summary {
                SummaryEditorSheet(summary: summary) { edited in
                    onSave(edited)
                    isPresented = false
                } onCancel: {
                    isPresented = false
                }
            }
        }
    }
}

public extension View {
    func summaryEditor(isPresented: Binding<Bool>, summary: TranscriptSummary?,
                       onSave: @escaping (TranscriptSummary) -> Void) -> some View {
        modifier(SummaryEditorPresentation(isPresented: isPresented, summary: summary, onSave: onSave))
    }
}

/// Editing the summary as four text areas. Lists are one item per line, which
/// is how a person would type them anyway.
public struct SummaryEditorSheet: View {
    @State private var overview: String
    @State private var keyPoints: String
    @State private var decisions: String
    @State private var actionItems: String
    private let original: TranscriptSummary
    private let onSave: (TranscriptSummary) -> Void
    private let onCancel: () -> Void

    public init(summary: TranscriptSummary,
                onSave: @escaping (TranscriptSummary) -> Void,
                onCancel: @escaping () -> Void) {
        original = summary
        _overview = State(initialValue: summary.overview)
        _keyPoints = State(initialValue: summary.keyPoints.joined(separator: "\n"))
        _decisions = State(initialValue: summary.decisions.joined(separator: "\n"))
        _actionItems = State(initialValue: summary.actionItems.joined(separator: "\n"))
        self.onSave = onSave
        self.onCancel = onCancel
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Overview") {
                    TextEditor(text: $overview)
                        .frame(minHeight: 80)
                        .accessibilityIdentifier("summary-edit-overview")
                }
                Section {
                    TextEditor(text: $keyPoints).frame(minHeight: 60)
                } header: {
                    Text("Key points")
                } footer: {
                    Text("One per line.")
                }
                Section("Decisions") {
                    TextEditor(text: $decisions).frame(minHeight: 44)
                }
                Section("Action items") {
                    TextEditor(text: $actionItems).frame(minHeight: 44)
                }
            }
            .navigationTitle("Edit Summary")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(edited) }
                        .accessibilityIdentifier("summary-edit-save")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 520)
        #endif
    }

    private var edited: TranscriptSummary {
        var result = original
        result.overview = overview
        result.keyPoints = lines(keyPoints)
        result.decisions = lines(decisions)
        result.actionItems = lines(actionItems)
        result.tidy()
        // Unchanged text is not an edit, so the attribution stays honest.
        if result.overview == original.overview, result.keyPoints == original.keyPoints,
           result.decisions == original.decisions, result.actionItems == original.actionItems {
            return original
        }
        result.editedAt = Date()
        return result
    }

    private func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { line in
            var item = line.trimmingCharacters(in: .whitespaces)
            // A pasted list keeps its bullets out of the data.
            for bullet in ["• ", "- ", "* "] where item.hasPrefix(bullet) {
                item.removeFirst(bullet.count)
            }
            return item
        }
    }
}
