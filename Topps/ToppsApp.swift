import SwiftUI

@main
struct ToppsApp: App {
    @StateObject private var store = ToppsStore()
    @AppStorage("showMenuBar") private var showMenuBar = true

    var body: some Scene {
        WindowGroup(id: "main") {
            MainWindowView()
                .environmentObject(store)
                .frame(minWidth: 1_160, minHeight: 720)
        }
        .defaultSize(width: 1_440, height: 860)
        .commands {
            CommandGroup(after: .sidebar) {
                Button("Refresh Now") { Task { await store.refresh() } }.keyboardShortcut("r")
                Button(store.refreshInterval == .paused ? "Resume Sampling" : "Pause Sampling") { store.refreshInterval = store.refreshInterval == .paused ? .oneSecond : .paused }.keyboardShortcut(".", modifiers: .command)
            }
            CommandMenu("Export") {
                Button("Export CSV…") { store.export(format: "csv") }
                Button("Export JSON…") { store.export(format: "json") }
            }
        }

        MenuBarExtra("Topps", systemImage: store.system.pressure == .critical ? "memorychip.fill" : "memorychip", isInserted: $showMenuBar) {
            MenuBarView().environmentObject(store)
        }.menuBarExtraStyle(.window)

        Settings { SettingsView().environmentObject(store) }
    }
}
