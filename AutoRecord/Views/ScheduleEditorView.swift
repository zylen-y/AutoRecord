import SwiftUI

struct ScheduleEditorView: View {
    enum Mode {
        case create
        case edit(Schedule)
    }

    @Environment(\.dismiss) private var dismiss

    let mode: Mode
    let onSave: (Schedule) -> Void

    @State private var title: String
    @State private var start: Date
    @State private var end: Date

    init(mode: Mode, onSave: @escaping (Schedule) -> Void) {
        self.mode = mode
        self.onSave = onSave
        switch mode {
        case .create:
            let defaultStart = Self.nextHalfHour(from: Date())
            _title = State(initialValue: "")
            _start = State(initialValue: defaultStart)
            _end = State(initialValue: defaultStart.addingTimeInterval(60 * 30))
        case .edit(let schedule):
            _title = State(initialValue: schedule.title)
            _start = State(initialValue: schedule.start)
            _end = State(initialValue: schedule.end)
        }
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty && end > start
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Title", text: $title, prompt: Text("Team standup, 1:1, etc."))
                    DatePicker("Start", selection: $start)
                    DatePicker("End", selection: $end, in: start...)
                }

                if !isValid {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Create") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding()
        }
        .frame(minWidth: 420, minHeight: 320)
    }

    private var validationMessage: String {
        if title.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Please give the schedule a title."
        }
        if end <= start {
            return "End time must be after the start time."
        }
        return ""
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        switch mode {
        case .create:
            let s = Schedule(title: trimmed, start: start, end: end)
            onSave(s)
        case .edit(let original):
            var updated = original
            updated.title = trimmed
            updated.start = start
            updated.end = end
            onSave(updated)
        }
        dismiss()
    }

    private static func nextHalfHour(from date: Date) -> Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let minute = comps.minute ?? 0
        let bump = minute < 30 ? 30 - minute : 60 - minute
        return cal.date(byAdding: .minute, value: bump, to: cal.date(from: DateComponents(
            year: comps.year, month: comps.month, day: comps.day,
            hour: comps.hour, minute: minute)) ?? date) ?? date
    }
}
