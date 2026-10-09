import SwiftUI
import LonghandKit

/// Every marker and note of a recording in one list, on both shells: the
/// transcript draws them where they fell, which is the right place to read
/// them and the wrong place to manage them. Tap plays from one; swipe or the
/// menu edits, moves or deletes it; the toolbar adds one at the playhead.
public struct MarkersSheet: View {
    public let markers: [Transcript.Marker]
    /// Where playback is, for "Add note here" and "Move here".
    public let playhead: TimeInterval
    public let onPlay: (Transcript.Marker) -> Void
    public let onAdd: (TimeInterval, String?) -> Void
    public let onRelabel: (Transcript.Marker, String) -> Void
    public let onMove: (Transcript.Marker, TimeInterval) -> Void
    public let onDelete: (Transcript.Marker) -> Void
    public let onDone: () -> Void

    @State private var editing: Transcript.Marker?
    @State private var adding = false
    @State private var draft = ""

    public init(markers: [Transcript.Marker], playhead: TimeInterval,
                onPlay: @escaping (Transcript.Marker) -> Void,
                onAdd: @escaping (TimeInterval, String?) -> Void,
                onRelabel: @escaping (Transcript.Marker, String) -> Void,
                onMove: @escaping (Transcript.Marker, TimeInterval) -> Void,
                onDelete: @escaping (Transcript.Marker) -> Void,
                onDone: @escaping () -> Void) {
        self.markers = markers
        self.playhead = playhead
        self.onPlay = onPlay
        self.onAdd = onAdd
        self.onRelabel = onRelabel
        self.onMove = onMove
        self.onDelete = onDelete
        self.onDone = onDone
    }

    public var body: some View {
        NavigationStack {
            Group {
                if markers.isEmpty {
                    ContentUnavailableView {
                        Label("No markers yet", systemImage: "flag")
                    } description: {
                        Text("Mark a moment or type a note while recording, or add one here at the playhead.")
                    }
                } else {
                    List {
                        ForEach(markers) { marker in
                            row(marker)
                        }
                    }
                    #if os(iOS)
                    .listStyle(.insetGrouped)
                    #endif
                }
            }
            .navigationTitle("Markers & Notes")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onDone)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        draft = ""
                        adding = true
                    } label: {
                        Label("Add note at \(TranscriptClock.label(playhead))", systemImage: "plus")
                    }
                    .accessibilityIdentifier("markers-add")
                }
            }
            .alert("Edit Note", isPresented: Binding(get: { editing != nil },
                                                     set: { if !$0 { editing = nil } })) {
                TextField("Note", text: $draft)
                Button("Save") {
                    if let marker = editing { onRelabel(marker, draft) }
                    editing = nil
                }
                Button("Cancel", role: .cancel) { editing = nil }
            } message: {
                if let marker = editing {
                    Text("At \(TranscriptClock.label(marker.time)). Leave it blank for a plain flag.")
                }
            }
            .alert("Add Note at \(TranscriptClock.label(playhead))", isPresented: $adding) {
                TextField("Note", text: $draft)
                Button("Add") {
                    onAdd(playhead, draft)
                    adding = false
                }
                Button("Cancel", role: .cancel) { adding = false }
            } message: {
                Text("Leave it blank for a plain flag.")
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 360)
        #endif
    }

    @ViewBuilder private func row(_ marker: Transcript.Marker) -> some View {
        Button {
            onPlay(marker)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: marker.label == nil ? "flag.fill" : "text.bubble.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(marker.label ?? "Marker")
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Text(TranscriptClock.label(marker.time))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(marker.label ?? "Marker") at \(TranscriptClock.label(marker.time))")
        .accessibilityHint("Plays from here")
        .accessibilityIdentifier("markers-row")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { onDelete(marker) } label: {
                Label("Delete", systemImage: "trash")
            }
            Button { beginEditing(marker) } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.accentColor)
        }
        .contextMenu {
            Button { beginEditing(marker) } label: { Label("Edit Note…", systemImage: "pencil") }
                .accessibilityIdentifier("markers-edit")
            Button { onMove(marker, playhead) } label: {
                Label("Move to \(TranscriptClock.label(playhead))", systemImage: "arrow.right.to.line")
            }
            .accessibilityIdentifier("markers-move")
            Divider()
            Button(role: .destructive) { onDelete(marker) } label: { Label("Delete", systemImage: "trash") }
                .accessibilityIdentifier("markers-delete")
        }
        .accessibilityAction(named: "Edit note") { beginEditing(marker) }
        .accessibilityAction(named: "Move to playhead") { onMove(marker, playhead) }
        .accessibilityAction(named: "Delete") { onDelete(marker) }
    }

    private func beginEditing(_ marker: Transcript.Marker) {
        draft = marker.label ?? ""
        editing = marker
    }
}

/// The transcript screen's note editor for a marker already drawn in the
/// text, where there is no row to swipe.
public struct MarkerEditAlert: ViewModifier {
    @Binding var marker: Transcript.Marker?
    let onSave: (Transcript.Marker, String) -> Void
    @State private var draft = ""

    public init(marker: Binding<Transcript.Marker?>, onSave: @escaping (Transcript.Marker, String) -> Void) {
        _marker = marker
        self.onSave = onSave
    }

    public func body(content: Content) -> some View {
        content
            .onChange(of: marker?.id) { _, _ in draft = marker?.label ?? "" }
            .alert("Edit Note", isPresented: Binding(get: { marker != nil },
                                                     set: { if !$0 { marker = nil } })) {
                TextField("Note", text: $draft)
                Button("Save") {
                    if let marker { onSave(marker, draft) }
                    marker = nil
                }
                Button("Cancel", role: .cancel) { marker = nil }
            } message: {
                if let marker {
                    Text("At \(TranscriptClock.label(marker.time)). Leave it blank for a plain flag.")
                }
            }
    }
}

public extension View {
    func markerEditor(_ marker: Binding<Transcript.Marker?>,
                      onSave: @escaping (Transcript.Marker, String) -> Void) -> some View {
        modifier(MarkerEditAlert(marker: marker, onSave: onSave))
    }

    /// The markers sheet and the note editor, wired to a screen model and a
    /// player, for either shell. `report` receives a failure's description.
    func markerPresentations(screen: TranscriptScreenModel, player: TranscriptPlayer,
                             showMarkers: Binding<Bool>, editingMarker: Binding<Transcript.Marker?>,
                             report: @escaping (String) -> Void) -> some View {
        modifier(MarkerPresentations(screen: screen, player: player, showMarkers: showMarkers,
                                     editingMarker: editingMarker, report: report))
    }
}

/// Both marker surfaces in one modifier, kept out of the transcript screens'
/// own modifier chains.
public struct MarkerPresentations: ViewModifier {
    let screen: TranscriptScreenModel
    let player: TranscriptPlayer
    @Binding var showMarkers: Bool
    @Binding var editingMarker: Transcript.Marker?
    let report: (String) -> Void

    public func body(content: Content) -> some View {
        content
            .markerEditor($editingMarker) { marker, label in
                attempt { try screen.relabelMarker(marker, to: label) }
            }
            .sheet(isPresented: $showMarkers) {
                MarkersSheet(markers: screen.markers, playhead: player.currentTime,
                             onPlay: { marker in player.seekAndPlay(to: marker.time) },
                             onAdd: { time, label in attempt { try screen.addMarker(at: time, label: label) } },
                             onRelabel: { marker, label in attempt { try screen.relabelMarker(marker, to: label) } },
                             onMove: { marker, time in attempt { try screen.moveMarker(marker, to: time) } },
                             onDelete: { marker in attempt { try screen.removeMarker(marker) } },
                             onDone: { showMarkers = false })
            }
    }

    private func attempt(_ change: () throws -> Void) {
        do { try change() } catch { report(JobLibraryModel.describe(error)) }
    }
}
