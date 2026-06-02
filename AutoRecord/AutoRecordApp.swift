import SwiftUI
import AppKit

@main
struct AutoRecordApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var store = ScheduleStore()
    @StateObject private var recorder = AudioRecorder()
    @StateObject private var scheduler = SchedulerService()

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopoverView()
                .environmentObject(store)
                .environmentObject(recorder)
                .environmentObject(scheduler)
                .frame(width: 320)
                .onAppear {
                    scheduler.attach(store: store, recorder: recorder)
                }
        } label: {
            Image(systemName: menuBarIcon)
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.window)

        Window("AutoRecord — Schedules", id: "schedules") {
            ScheduleListView()
                .environmentObject(store)
                .environmentObject(recorder)
                .frame(minWidth: 480, minHeight: 360)
        }

        Settings {
            SettingsView()
                .environmentObject(recorder)
                .frame(width: 460)
                .padding()
        }
    }

    private var menuBarIcon: String {
        if recorder.isRecording { return "record.circle.fill" }
        if PermissionService.micStatus == .denied { return "mic.slash" }
        return "mic"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }
}
