import Foundation
import LonghandKit
import LonghandEngines

/// The iOS shell's single `JobLibraryModel`, wired with the two iOS-only
/// pieces: a `BGContinuedProcessingTask` around every run (§11.1) and the
/// status push to the watch. One instance, because the library view and the
/// watch receiver must see the same job state.
@MainActor
enum AppLibrary {

    static let model: JobLibraryModel = {
        JobLibraryModel(
            backgroundWrapper: { jobID, title, progress, work in
                try await BackgroundExecutionCoordinator.shared.run(
                    jobID: jobID,
                    title: String(localized: "Transcribing “\(title)”"),
                    progress: progress,
                    work: work)
            },
            onRefresh: { latest in
                guard let latest else { return }
                WatchLink.shared.push(jobID: latest.id, title: latest.title,
                                      state: latest.state.rawValue)
            })
    }()

    /// Here rather than in the shared model, which knows nothing about a wrist.
    @MainActor
    static func startWatchReporting() {
        model.onProgress = { jobID, progress in
            guard let job = model.job(jobID) else { return }
            WatchLink.shared.pushProgress(jobID: jobID, title: job.title, progress: progress)
        }
    }
}

// MARK: - UI-test synth import

extension JobLibraryModel {

    /// Processes `--uitest-synth-import <langs>` sequentially through the real
    /// import + pipeline path. No-op outside UI tests.
    func runUITestSynthImportIfRequested() {
        #if DEBUG
        let languages = UITestSupport.requestedLanguages
        guard !languages.isEmpty, !UITestSupport.didRunSynthImport else { return }
        UITestSupport.didRunSynthImport = true
        Task {
            for language in languages {
                do {
                    let url = try await UITestSupport.renderSample(language: language)
                    let imported = try await Task.detached {
                        try await ImportService.importRecording(from: url, securityScoped: false,
                                                                declaredLanguage: language,
                                                                expectedSpeakerCount: nil)
                    }.value
                    try? FileManager.default.removeItem(at: url)
                    refresh()
                    await run(jobID: imported.record.id, userConfirmedRawPCM: false)
                } catch {
                    refresh()
                }
            }
        }
            #endif
}
}
