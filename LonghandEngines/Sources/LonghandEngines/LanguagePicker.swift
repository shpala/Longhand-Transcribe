import SwiftUI

/// The language choice, grouped by what it costs, so the size is disclosed
/// before the recording rather than at the §4.2.3(ii) gate mid-job. The model
/// group is 90 languages, so only a few are inline and the rest sit behind a
/// searchable list.
public struct LanguagePicker: View {
    @Binding public var declaredLanguage: String
    @State private var catalog = TranscriptionLanguages.shared
    @State private var showingAll = false

    public init(declaredLanguage: Binding<String>) {
        self._declaredLanguage = declaredLanguage
    }

    /// The recent ones plus whatever is selected: a `Picker` renders blank
    /// when its selection is not among its own items, so a language chosen from
    /// the full list has to appear here afterwards.
    private var inlineModelLanguages: [TranscriptionLanguage] {
        var languages = catalog.recentModelLanguages
        if catalog.needsModel.contains(where: { $0.code == declaredLanguage }),
           !languages.contains(where: { $0.code == declaredLanguage }) {
            languages.insert(TranscriptionLanguage(code: declaredLanguage), at: 0)
        }
        return languages
    }

    public var body: some View {
        Picker("Language", selection: $declaredLanguage) {
            // Named, not just "Automatic": this is the setting that can hand
            // Hebrew audio to an English engine and get confident nonsense back.
            Text(catalog.label(for: TranscriptionLanguages.systemSentinel))
                .tag(TranscriptionLanguages.systemSentinel)

            Section(TranscriptionLanguages.onDeviceHeader) {
                ForEach(catalog.onDevice) { language in
                    Text(language.name).tag(language.code)
                }
            }

            Section(catalog.modelHeader) {
                // A mode rather than a language, so it leads the group. Whisper
                // decodes one language per ~30 s window, which helps a recording
                // that changes language in long stretches and hurts one that
                // code-switches inside a sentence, hence the plain label.
                Text("Mixed · detected every 30 seconds")
                    .tag(TranscriptionLanguages.mixedSentinel)
                ForEach(inlineModelLanguages) { language in
                    Text(language.name).tag(language.code)
                }
            }
        }
        // The section header above is also called "Language", so the tests
        // need something that names this control and not that.
        .accessibilityIdentifier("language-picker")
        .onChange(of: declaredLanguage) { _, new in catalog.remember(new) }
        // The catalogue loads once, asynchronously, and nothing else in this
        // view triggers it.
        .task { await catalog.load() }

        Button("More languages…") { showingAll = true }
            .accessibilityIdentifier("more-languages")
            .sheet(isPresented: $showingAll) {
                LanguageListView(declaredLanguage: $declaredLanguage)
            }

        Text(TranscriptionLanguages.bothAreLocalNote)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// Every language the app can be told to transcribe, searchable. A sheet
/// rather than a `NavigationLink` because the Mac's Settings form has no
/// navigation stack to push onto.
public struct LanguageListView: View {
    @Binding public var declaredLanguage: String
    @State private var catalog = TranscriptionLanguages.shared
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    public init(declaredLanguage: Binding<String>) {
        self._declaredLanguage = declaredLanguage
    }

    private func matching(_ languages: [TranscriptionLanguage]) -> [TranscriptionLanguage] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return languages }
        return languages.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    public var body: some View {
        NavigationStack {
            List {
                let onDevice = matching(catalog.onDevice)
                let needsModel = matching(catalog.needsModel)
                if !onDevice.isEmpty {
                    Section(TranscriptionLanguages.onDeviceHeader) { rows(onDevice) }
                }
                if !needsModel.isEmpty {
                    Section(catalog.modelHeader) { rows(needsModel) }
                }
                if onDevice.isEmpty, needsModel.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, prompt: "Search languages")
            .navigationTitle("Language")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await catalog.load() }
    }

    @ViewBuilder
    private func rows(_ languages: [TranscriptionLanguage]) -> some View {
        ForEach(languages) { language in
            Button {
                declaredLanguage = language.code
                catalog.remember(language.code)
                dismiss()
            } label: {
                HStack {
                    Text(language.name)
                    Spacer()
                    if language.code == declaredLanguage {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// The same two groups as a flat menu, for "Re-transcribe in…" (§13.2), where
/// a `Picker` has no selection to show and a sheet cannot be opened. The model
/// group is the recent few rather than all 90.
public struct LanguageMenuItems: View {
    /// nil means "no declaration"; the closure re-runs the job.
    public let pick: (String?) -> Void
    @State private var catalog = TranscriptionLanguages.shared

    public init(pick: @escaping (String?) -> Void) {
        self.pick = pick
    }

    public var body: some View {
        Group {
            Button(catalog.label(for: TranscriptionLanguages.systemSentinel)) { pick(nil) }
            Section(TranscriptionLanguages.onDeviceHeader) {
                ForEach(catalog.onDevice) { language in
                    Button(language.name) { pick(language.code) }
                }
            }
            Section(catalog.modelHeader) {
                Button("Mixed · detected every 30 seconds") {
                    pick(TranscriptionLanguages.mixedSentinel)
                }
                ForEach(catalog.recentModelLanguages) { language in
                    Button(language.name) { pick(language.code) }
                }
            }
        }
        .task { await catalog.load() }
    }
}
