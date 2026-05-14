import SwiftUI
import AutoRecordShared

struct MenuBarPopoverView: View {
    @EnvironmentObject var store: ScheduleStore
    @EnvironmentObject var recorder: AudioRecorder
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var now = Date()

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            currentRecordingSection
            upcomingSection
            Divider()
            buttons
        }
        .padding(14)
        .onReceive(ticker) { now = $0 }
    }

    private var header: some View {
        HStack {
            Image(systemName: recorder.isRecording ? "record.circle.fill" : "mic")
                .foregroundColor(recorder.isRecording ? .red : .secondary)
            Text("AutoRecord").font(.headline)
            Spacer()
            if PermissionService.micStatus == .denied {
                Text("No mic access")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }

    @ViewBuilder
    private var currentRecordingSection: some View {
        if recorder.isRecording, let s = recorder.currentSchedule, let started = recorder.startedAt {
            VStack(alignment: .leading, spacing: 4) {
                Text("Recording")
                    .font(.caption.smallCaps())
                    .foregroundColor(.secondary)
                Text(s.title).font(.body.bold())
                Text("Elapsed: \(formatDuration(now.timeIntervalSince(started)))")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                Text("Ends: \(formatTime(s.end))")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button(role: .destructive) {
                    recorder.stopAndPrompt()
                } label: {
                    Label("Stop now", systemImage: "stop.circle")
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private var upcomingSection: some View {
        if !recorder.isRecording {
            if let next = store.nextUpcoming(now: now) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Next up")
                        .font(.caption.smallCaps())
                        .foregroundColor(.secondary)
                    Text(next.title).font(.body.bold())
                    Text("Starts in \(formatDuration(next.start.timeIntervalSince(now)))")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                    Text("\(formatTime(next.start)) – \(formatTime(next.end))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                Text("No upcoming schedules")
                    .font(.body)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var buttons: some View {
        VStack(spacing: 6) {
            Button {
                openWindow(id: "schedules")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Open Manager…", systemImage: "calendar")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)

            Button {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Settings…", systemImage: "gear")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit AutoRecord", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
        }
    }

    private func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return f.string(from: date)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
