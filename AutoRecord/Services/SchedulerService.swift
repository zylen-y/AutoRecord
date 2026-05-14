import Foundation
import AutoRecordShared
import Combine

@MainActor
final class SchedulerService: ObservableObject {
    private weak var store: ScheduleStore?
    private weak var recorder: AudioRecorder?

    private var startTimers: [UUID: Timer] = [:]
    private var endTimers: [UUID: Timer] = [:]
    private var cancellables = Set<AnyCancellable>()

    func attach(store: ScheduleStore, recorder: AudioRecorder) {
        self.store = store
        self.recorder = recorder
        // Rebuild timers whenever schedules change.
        store.$schedules
            .sink { [weak self] schedules in
                self?.rebuild(from: schedules)
            }
            .store(in: &cancellables)
        rebuild(from: store.schedules)
    }

    func rebuild(from schedules: [Schedule]) {
        // Cancel all existing timers.
        startTimers.values.forEach { $0.invalidate() }
        endTimers.values.forEach { $0.invalidate() }
        startTimers.removeAll()
        endTimers.removeAll()

        let now = Date()
        // The currently-active recording schedule, if any, should be honored.
        let activeRecordingId = recorder?.currentSchedule?.id

        for schedule in schedules {
            // Future start
            if schedule.start > now {
                let interval = schedule.start.timeIntervalSinceNow
                let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        await self?.onStart(scheduleId: schedule.id)
                    }
                }
                startTimers[schedule.id] = t
            }
            // Future end
            if schedule.end > now {
                let interval = schedule.end.timeIntervalSinceNow
                let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        await self?.onEnd(scheduleId: schedule.id)
                    }
                }
                endTimers[schedule.id] = t
            }

            // If we're currently inside a window AND we're not already recording it, start now.
            if schedule.status(now: now) == .active, activeRecordingId != schedule.id, recorder?.isRecording == false {
                Task { @MainActor in
                    await self.onStart(scheduleId: schedule.id)
                }
            }
        }
    }

    private func onStart(scheduleId: UUID) async {
        guard let schedule = store?.schedule(id: scheduleId) else { return }
        guard recorder?.isRecording == false else {
            NSLog("SchedulerService: already recording, skipping start for \(schedule.title)")
            return
        }
        await recorder?.startRecording(for: schedule)
    }

    private func onEnd(scheduleId: UUID) async {
        guard let recorder = recorder else { return }
        // Only prompt if this schedule is the one currently being recorded.
        guard recorder.currentSchedule?.id == scheduleId else { return }
        recorder.stopAndPrompt()
    }
}
