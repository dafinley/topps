import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: ToppsStore
    @AppStorage("showMenuBar") private var showMenuBar = true
    @AppStorage("continueWhenHidden") private var continueWhenHidden = true
    @AppStorage("exactBytes") private var exactBytes = false
    @AppStorage("attentionMemoryGB") private var attentionMemoryGB = 2.0
    @AppStorage("attentionCPU") private var attentionCPU = 80.0
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    var body: some View {
        Form {
            Section("Sampling") {
                Picker("Refresh interval", selection: $store.refreshInterval) { ForEach(RefreshInterval.allCases) { Text($0.label).tag($0) } }
                Picker("Default sort", selection: $store.sort) { ForEach(ProcessSort.allCases) { Text($0.rawValue).tag($0) } }
                Toggle("Continue full-rate sampling when the main window is hidden", isOn: $continueWhenHidden)
            }
            Section("Presentation") {
                Toggle("Show menu bar item", isOn: $showMenuBar)
                Toggle("Prefer exact byte values", isOn: $exactBytes)
            }
            Section("Attention indicators") {
                HStack { Text("Memory threshold"); Slider(value: $attentionMemoryGB, in: 0.5...16, step: 0.5); Text("\(attentionMemoryGB.formatted()) GB").monospacedDigit().frame(width: 55) }
                HStack { Text("CPU threshold"); Slider(value: $attentionCPU, in: 10...400, step: 10); Text("\(Int(attentionCPU))%").monospacedDigit().frame(width: 55) }
                Text("Indicators help prioritize investigation; they do not imply a process is malicious or leaking.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Startup") {
                Toggle("Launch Topps at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in updateLogin(enabled) }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }
            Section("Privacy") {
                Text("Topps itself runs locally and sends no analytics or process information anywhere. Storage snapshots remain in Application Support and contain paths plus aggregate sizes. Optional external tools may have their own network behavior.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 540, height: 500)
    }

    private func updateLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = enabled
            loginError = nil
        } catch { loginError = error.localizedDescription; launchAtLogin = SMAppService.mainApp.status == .enabled }
    }
}

struct MenuBarView: View {
    @EnvironmentObject private var store: ToppsStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("Topps").font(.headline); Spacer(); PressureBadge(pressure: store.system.pressure) }
            VStack(alignment: .leading, spacing: 5) {
                HStack { Text("Memory"); Spacer(); Text("\(ByteFormat.string(store.system.usedMemory)) / \(ByteFormat.string(store.system.totalMemory))").monospacedDigit() }
                MemoryBar(system: store.system, showsLegend: false)
            }
            Divider()
            menuSection("Top Footprint", values: Array(store.processes.sorted { $0.memory > $1.memory }.prefix(3))) { ByteFormat.string($0.memory) }
            menuSection("Top CPU", values: Array(store.processes.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(3))) { String(format: "%.1f%%", $0.cpuPercent) }
            Divider()
            Button("Open Topps") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }.keyboardShortcut(.defaultAction).frame(maxWidth: .infinity)
        }.padding(12).frame(width: 320)
    }

    private func menuSection(_ title: String, values: [ProcessSnapshot], value: @escaping (ProcessSnapshot) -> String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(values) { process in HStack { ProcessIcon(process: process, size: 17); Text(process.name).lineLimit(1); Spacer(); Text(value(process)).monospacedDigit().foregroundStyle(.secondary) } }
        }
    }
}
