import SwiftUI
import LonghandEngines

/// The re-transcribe language list, written once for the three menus that
/// show it.
struct RetranscribeLanguageItems: View {
    /// nil means "system default"; the closure does the actual re-transcribing.
    let pick: (String?) -> Void

    var body: some View {
        LanguageMenuItems(pick: pick)
    }
}

/// A failure the user can do something about, as opposed to a single-OK alert
/// that makes a transient disk hiccup look as fatal as data loss.
struct RetryableError: Identifiable {
    let id = UUID()
    let message: String
    /// Re-runs the operation that failed; nil when there is nothing to redo.
    var retry: (() -> Void)?
}

extension View {
    func retryableErrorAlert(_ error: Binding<RetryableError?>) -> some View {
        alert("Something Went Wrong",
              isPresented: Binding(get: { error.wrappedValue != nil },
                                   set: { if !$0 { error.wrappedValue = nil } })) {
            if let retry = error.wrappedValue?.retry {
                Button("Retry") {
                    error.wrappedValue = nil
                    retry()
                }
            }
            Button("OK") { error.wrappedValue = nil }
        } message: {
            Text(error.wrappedValue?.message ?? "")
        }
    }
}
