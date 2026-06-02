import SwiftUI
import AutoRecordShared

struct ScheduleListView: View {
    @EnvironmentObject var store: ScheduleStore
    @EnvironmentObject var recorder: AudioRecorder
    @State private var editing: Schedule?
    @State private var showingNew = false
    @State private var now = Date()

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                recordingBanner
                Group {
                    if store.schedules.isEmpty {
                        emptyState
                    } else {
                        list
                    }
                }
            }
            .navigationTitle("Schedules")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingNew = true
                    } label: {
                        Label("New schedule", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showingNew) {
            ScheduleEditorView(mode: .create) { newSchedule in
                store.add(newSchedule)
            }
        }
        .sheet(item: $editing) { schedule in
            ScheduleEditorView(mode: .edit(schedule)) { updated in
                store.update(updated)
            }
        }
        .onReceive(ticker) { now = $0 }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 42))
                .foregroundColor(.secondary)
            Text("No schedules yet").font(.title3)
            Text("Click + to add one. AutoRecord will start recording at the start time and prompt you to save at the end.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal)
            Button {
                showingNew = true
            } label: {
                Label("Add schedule", systemImage: "plus")
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    @ViewBuilder
    private var recordingBanner: some View {
        if recorder.isRecording,
           let schedule = recorder.currentSchedule,
           let startedAt = recorder.startedAt {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Recording — \(schedule.title)")
                        .font(.subheadline.bold())
                    Text("Elapsed \(formatElapsed(now.timeIntervalSince(startedAt)))")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(role: .destructive) {
                    recorder.stopAndPrompt()
                } label: {
                    Label("Stop", systemImage: "stop.circle")
                }
                .controlSize(.regular)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.red.opacity(0.10))
            .overlay(
                Rectangle()
                    .fill(Color.red.opacity(0.30))
                    .frame(height: 1),
                alignment: .bottom
            )
        }
    }

    private func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    private var list: some View {
        List {
            ForEach(store.schedules) { schedule in
                row(for: schedule)
                    .contentShape(Rectangle())
                    .onTapGesture { editing = schedule }
                    .contextMenu {
                        Button("Edit") { editing = schedule }
                        Button("Delete", role: .destructive) { store.delete(id: schedule.id) }
                    }
            }
            .onDelete { indices in
                let ids = indices.map { store.schedules[$0].id }
                ids.forEach { store.delete(id: $0) }
            }
        }
    }

    private func row(for schedule: Schedule) -> some View {
        HStack(alignment: .top, spacing: 12) {
            statusIndicator(for: schedule)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 4) {
                Text(schedule.title).font(.headline)
                Text("\(formatDate(schedule.start)) · \(formatTime(schedule.start)) – \(formatTime(schedule.end))")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text(durationLabel(schedule))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            statusBadge(for: schedule)
        }
        .padding(.vertical, 4)
    }

    /// `Schedule.status(now:)` is purely time-based, so it can lie in two cases:
    /// (a) the user stopped early during the window — schedule's end is the future, but recording is over;
    /// (b) the user chose Continue Recording past the window — schedule.end is in the past, but recording is still going.
    /// The recorder's `currentSchedule` is the authoritative override.
    private func effectiveStatus(for schedule: Schedule) -> Schedule.Status {
        if recorder.isRecording, recorder.currentSchedule?.id == schedule.id {
            return .active
        }
        return schedule.status(now: now)
    }

    private func statusIndicator(for schedule: Schedule) -> some View {
        let color: Color
        switch effectiveStatus(for: schedule) {
        case .upcoming: color = .blue
        case .active: color = .red
        case .past: color = .gray
        }
        return Circle().fill(color).frame(width: 8, height: 8)
    }

    @ViewBuilder
    private func statusBadge(for schedule: Schedule) -> some View {
        switch effectiveStatus(for: schedule) {
        case .active:
            Text("RECORDING")
                .font(.caption2.bold())
                .foregroundColor(.white)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.red)
                .clipShape(Capsule())
        case .upcoming:
            Text("UPCOMING")
                .font(.caption2.bold())
                .foregroundColor(.white)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.blue)
                .clipShape(Capsule())
        case .past:
            Text("PAST")
                .font(.caption2.bold())
                .foregroundColor(.white)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.gray)
                .clipShape(Capsule())
        }
    }

    private func durationLabel(_ s: Schedule) -> String {
        let mins = Int(s.end.timeIntervalSince(s.start) / 60)
        let h = mins / 60
        let m = mins % 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }

    private func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
