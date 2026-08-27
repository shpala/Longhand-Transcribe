import SwiftUI

/// The record surface: indigo field, cream monospaced timer, waveform-script
/// stroke as the live level, red stop. One screen, since the watch is a
/// capture device.
struct WatchRecordView: View {

    @State private var recorder = WatchRecorderService()
    @State private var transfer = WatchTransfer.shared
    @State private var permissionDenied = false
    @State private var markers: [TimeInterval] = []
    @State private var locationCapture = WatchLocationCapture()
    @State private var capturedLocation: WatchLocationCapture.Fix?
    @State private var showHandoffHint = false
    @State private var showStopConfirmation = false
    @State private var showCancelSendConfirmation = false
    /// Fixed once, so the elapsed timer's schedule does not move when the view
    /// re-renders for an unrelated reason.
    @State private var timerAnchor = Date()

    private let cream = Color("LonghandCream")

    var body: some View {
        VStack(spacing: 6) {
            if permissionDenied {
                Text("Allow microphone access in Settings on your iPhone.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(cream)
            } else {
                switch recorder.state {
                case .idle, .finished:
                    idleView
                case .recording, .paused:
                    recordingView
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color("LonghandIndigo").ignoresSafeArea())
        .task { transfer.activate() }
        // Anchored on `body`, not in `recordingView`: that subtree is
        // invalidated several times a second and is torn down the instant
        // `stop()` sets `.finished`, so a dialog presented from it would be
        // presented by a view that is animating and disappearing at once.
        .confirmationDialog("Finish this take?", isPresented: $showStopConfirmation) {
            Button("Send") {
                Task {
                    if let url = await recorder.stop() {
                        transfer.send(url, markers: markers, location: capturedLocation)
                    }
                }
            }
            Button("Discard", role: .destructive) {
                recorder.discard()
                markers = []
                capturedLocation = nil
            }
            Button("Keep Recording", role: .cancel) {}
        }
        .onOpenURL { url in
            // Matched on shape, not against a shared constant: the complication
            // is its own target and cannot be imported, so the URL is the
            // contract between them (see `ComplicationLink`).
            guard url.scheme == "longhand", url.host == "record" else { return }
            Task { await beginRecording() }
        }
        // Watch simulators accept no synthetic taps, so "--uitest-autotake N"
        // records N seconds and sends, making the hand-off assertable.
        .task {
            let args = ProcessInfo.processInfo.arguments
            guard let index = args.firstIndex(of: "--uitest-autotake"), index + 1 < args.count,
                  let seconds = Double(args[index + 1]) else { return }
            guard await WatchRecorderService.requestPermission() else { return }
            await recorder.start()
            // Marking every couple of seconds is the part worth exercising: a
            // `@State` change on this view while the meter and timer tick is
            // the shape both reported freezes had in common.
            let marksEvery = 2.0
            var elapsed = 0.0
            while elapsed < seconds {
                try? await Task.sleep(for: .seconds(min(marksEvery, seconds - elapsed)))
                elapsed += marksEvery
                if elapsed < seconds { markers.append(recorder.currentTime) }
            }
            try? await Task.sleep(for: .seconds(0))
            if let url = await recorder.stop() {
                transfer.send(url)
            }
        }
    }

    /// The one way a take starts, from the Record button or the complication.
    /// A running take is left alone, so a second complication tap mid-recording
    /// cannot restart it.
    private func beginRecording() async {
        guard recorder.state == .idle || recorder.state == .finished else { return }
        guard await WatchRecorderService.requestPermission() else {
            permissionDenied = true
            return
        }
        // Markers and the fix belong to the recording that produced them.
        markers = []
        capturedLocation = nil
        await recorder.start()
        if transfer.captureLocationEnabled {
            // Resolved alongside the recording; never blocks it.
            capturedLocation = await locationCapture.capture()
        }
    }

    private var idleView: some View {
        VStack(spacing: 10) {
            Button {
                Task { await beginRecording() }
            } label: {
                ZStack {
                    Circle().fill(.red)
                    Image(systemName: "mic.fill")
                        .font(.title2)
                        .foregroundStyle(cream)
                }
                .frame(width: 64, height: 64)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Record")
            Text("Record")
                .font(.footnote)
                .foregroundStyle(cream.opacity(0.7))
            if let sending = transfer.sendProgress {
                // Two waits, one bar each: this is "leaving the watch", the one
                // below is "the phone is working on it", hence the captions.
                Text("Sending to iPhone…")
                    .font(.caption2)
                    .foregroundStyle(cream.opacity(0.7))
                ProgressView(value: sending)
                    .tint(cream)
                    .padding(.horizontal, 20)
            } else if let progress = transfer.phoneProgress {
                Text("Transcribing on iPhone…")
                    .font(.caption2)
                    .foregroundStyle(cream.opacity(0.7))
                ProgressView(value: progress)
                    .tint(cream)
                    .padding(.horizontal, 20)
            }
            if let status = transfer.statusLine {
                Text(status)
                    .font(.caption2)
                    // Actionable lines earn full contrast; chatter stays dim.
                    .foregroundStyle(cream.opacity(transfer.statusIsAlert ? 0.9 : 0.55))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            if transfer.failedTake != nil {
                Button("Retry send") { transfer.retryFailedTake() }
                    .font(.caption2)
                    .foregroundStyle(cream.opacity(0.9))
                    .buttonStyle(.plain)
            } else if transfer.pendingTransfers > 0 {
                // Withdraws every queued take and deletes each one, so the
                // count is on the button and the dialog spells out the cost.
                Button(transfer.pendingTransfers == 1
                       ? "Cancel send" : "Cancel \(transfer.pendingTransfers) sends",
                       role: .destructive) { showCancelSendConfirmation = true }
                    .font(.caption2)
                    .buttonStyle(.plain)
            }
            if transfer.hasDeliveredTake {
                // No API lets watchOS foreground an app on the phone, so
                // Handoff is the whole mechanism: this advertises the activity
                // and the user completes it on the phone. All the button can
                // honestly do is say where to go.
                Button {
                    showHandoffHint.toggle()
                } label: {
                    Label(showHandoffHint ? "App Switcher, bottom of the screen"
                                          : "Continue on iPhone",
                          systemImage: showHandoffHint ? "arrow.up.left.square" : "iphone.and.arrow.forward")
                        .font(.caption2)
                        .foregroundStyle(cream.opacity(0.8))
                        .multilineTextAlignment(.center)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 8)
        .confirmationDialog(transfer.pendingTransfers == 1
                            ? "Cancel this send?"
                            : "Cancel \(transfer.pendingTransfers) queued sends?",
                            isPresented: $showCancelSendConfirmation) {
            Button("Cancel and Delete", role: .destructive) { transfer.cancelPendingTransfers() }
            Button("Keep Waiting", role: .cancel) {}
        } message: {
            Text(transfer.pendingTransfers == 1
                 ? "The recording is deleted from this watch. This can't be undone."
                 : "All \(transfer.pendingTransfers) recordings are deleted from this watch. This can't be undone.")
        }
        .userActivity(WatchTransfer.handoffActivityType, isActive: transfer.hasDeliveredTake) { activity in
            activity.title = "Longhand"
            activity.isEligibleForHandoff = true
        }
    }

    private var recordingView: some View {
        VStack(spacing: 8) {
            // `.now` here would be re-evaluated on every body pass, so each
            // state change (a marker, say) would restart the schedule.
            TimelineView(.periodic(from: timerAnchor, by: 0.5)) { _ in
                Text(elapsed)
                    .font(.system(size: 30, weight: .light).monospacedDigit())
                    .foregroundStyle(cream)
            }
            WatchWaveformMeter(recorder: recorder)
                .frame(height: 30)
                .opacity(recorder.state == .paused ? 0.35 : 1)
            if let error = recorder.lastError {
                Text(error)
                    .font(.caption2).foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            if recorder.isInterrupted {
                Text("Interrupted, not recording")
                    .font(.caption2).foregroundStyle(.orange)
            }
            if !markers.isEmpty {
                Text("\(markers.count) marked")
                    .font(.caption2).foregroundStyle(cream.opacity(0.7))
            }
            HStack(spacing: 14) {
                Button {
                    if recorder.state == .recording { recorder.pause() } else { recorder.resume() }
                } label: {
                    Image(systemName: recorder.state == .recording ? "pause.circle.fill" : "record.circle")
                        .font(.title3)
                }
                .tint(recorder.isInterrupted ? .orange : cream)
                .buttonStyle(.plain)
                .foregroundStyle(cream)
                .accessibilityLabel(recorder.state == .recording ? "Pause" : "Resume")
                Button {
                    markers.append(recorder.currentTime)
                } label: {
                    Image(systemName: "flag.fill").font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(cream)
                .disabled(recorder.state != .recording)
                .accessibilityLabel(markers.isEmpty ? "Mark this moment"
                                                    : "Mark this moment. \(markers.count) so far")
                // Two-step, so a bad take can be discarded rather than sent.
                Button {
                    showStopConfirmation = true
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 34))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .accessibilityLabel("Stop")
            }
        }
    }

    private var elapsed: String {
        let total = Int(recorder.currentTime)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

/// A drawing of the recorder's published levels, nothing more. Owning the
/// history in `@State` and refilling it from `onChange(of: context.date)`
/// inside a `TimelineView` mutates state during a view update and ties the
/// meter's cadence to how often the whole screen re-renders, which on a Series
/// 7 is the shape of a wrist that stops responding. The sampling lives in
/// `WatchRecorderService`.
private struct WatchWaveformMeter: View {
    let recorder: WatchRecorderService

    var body: some View {
        Canvas { graphics, size in
            let history = recorder.levelHistory
            let midY = size.height / 2
            let amplitude = size.height * 0.45
            let count = history.count
            guard count > 1 else { return }
            func point(_ index: Int, _ level: Double, _ sign: CGFloat) -> CGPoint {
                CGPoint(x: CGFloat(index) / CGFloat(count - 1) * size.width,
                        y: midY - sign * CGFloat(max(0.05, level)) * amplitude)
            }
            let top = history.enumerated().map { point($0, $1, 1) }
            let bottom = history.enumerated().reversed().map { point($0, $1, -1) }
            var path = Path()
            path.addSmoothCurve(through: top)
            path.addSmoothCurve(through: bottom, continuing: true)
            path.closeSubpath()
            graphics.fill(path, with: .color(Color("LonghandCream")))
        }
        .accessibilityLabel("Microphone level")
    }
}

private extension Path {
    mutating func addSmoothCurve(through points: [CGPoint], continuing: Bool = false) {
        guard let first = points.first, points.count > 1 else { return }
        if !continuing { move(to: first) } else { addLine(to: first) }
        for i in 1..<points.count {
            let previous = points[i - 1]
            let current = points[i]
            let midpoint = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
            addQuadCurve(to: midpoint, control: previous)
        }
        addLine(to: points[points.count - 1])
    }
}
