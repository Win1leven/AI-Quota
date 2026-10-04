import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: QuotaStore

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }

            codexTab
                .tabItem { Label("Codex", systemImage: "chevron.left.forwardslash.chevron.right") }

            claudeTab
                .tabItem { Label("Claude", systemImage: "bubble.left.and.bubble.right") }

            historyTab
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }

            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 340)
        .fixedSize()
    }

    private var generalTab: some View {
        Form {
            Picker("Menu bar display:", selection: Binding(
                get: { store.settings.menuBarMode },
                set: { store.settings.menuBarMode = $0; store.saveSettings() }
            )) {
                ForEach(MenuBarMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }

            Toggle("Launch at startup", isOn: Binding(
                get: { store.settings.launchAtStartup },
                set: { store.settings.launchAtStartup = $0; store.saveSettings() }
            ))

            Picker("Codex refresh interval:", selection: Binding(
                get: { store.settings.codexRefreshInterval },
                set: { store.settings.codexRefreshInterval = $0; store.saveSettings() }
            )) {
                Text("60 seconds").tag(TimeInterval(60))
                Text("2 minutes").tag(TimeInterval(120))
                Text("5 minutes").tag(TimeInterval(300))
            }

            Picker("Default trend range:", selection: Binding(
                get: { store.settings.defaultTrendRange },
                set: { store.settings.defaultTrendRange = $0; store.saveSettings() }
            )) {
                ForEach(TrendRange.allCases, id: \.self) { range in
                    Text(range.rawValue).tag(range)
                }
            }

            Toggle("Show on all spaces", isOn: Binding(
                get: { store.settings.showOnAllSpaces },
                set: { store.settings.showOnAllSpaces = $0; store.saveSettings() }
            ))

            Toggle("Always on top (floating panel)", isOn: Binding(
                get: { store.settings.alwaysOnTop },
                set: { store.settings.alwaysOnTop = $0; store.saveSettings() }
            ))
        }
        .padding()
        .formStyle(.grouped)
    }

    private var codexTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Codex CLI")
                .font(.headline)

            Text("The app communicates with Codex through the `codex app-server` command.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    let provider = store.getProvider(.codex) as? CodexQuotaProvider
                    let path = provider?.detectedPath ?? "unknown"
                    let installed = provider?.isAvailable ?? false

                    LabeledContent("Detected path:") {
                        Text(path)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(installed ? Color.primary : Color.red)
                    }

                    LabeledContent("Source:") {
                        Text(path.contains("ChatGPT.app") ? "Codex Desktop App" : path.contains("which") ? "not found" : "Codex CLI")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }

                    if !installed {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.system(size: 10))
                            Text("Codex not found. Install via Homebrew, install Codex Desktop App, or set the path below.")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    HStack {
                        TextField("Custom path (optional)", text: Binding(
                            get: { provider?.customPath ?? "" },
                            set: { provider?.customPath = $0 }
                        ))
                        .font(.system(size: 10, design: .monospaced))
                        .textFieldStyle(.roundedBorder)

                        Button("Clear") {
                            provider?.customPath = nil
                        }
                        .controlSize(.small)
                    }
                }
                .padding(8)
            }

            Spacer()
        }
        .padding()
    }

    private var claudeTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude Code Status Line Collector")
                .font(.headline)

            Text("The collector reads quota data from Claude Code's status line and saves it to a local snapshot file.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: store.snapshots[.claude] != nil ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(store.snapshots[.claude] != nil ? .green : .gray)
                        Text(store.snapshots[.claude] != nil ? "Collector active" : "Collector not configured")
                            .font(.system(size: 12))
                    }

                    if store.snapshots[.claude] != nil {
                        if let snap = store.snapshots[.claude] {
                            Text("Sampled: \(snap.observedAt.formatted())")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(8)
            }

            HStack(spacing: 8) {
                Button("Install / Enable") {
                    // Future: trigger ClaudeCollectorManager
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Restore Original Config") {
                    // Future: trigger collectManager.restore()
                }
                .controlSize(.small)
            }

            Text("Configuration file: ~/.claude/settings.json")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .padding()
    }

    private var historyTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Local Data History")
                .font(.headline)

            Text("Trend data is stored locally for the selected retention period.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Picker("Retention period:", selection: Binding(
                get: { store.settings.historyRetentionDays },
                set: { store.settings.historyRetentionDays = $0; store.saveSettings() }
            )) {
                Text("7 days").tag(7)
                Text("30 days").tag(30)
                Text("90 days").tag(90)
            }
            .pickerStyle(.radioGroup)

            Button(role: .destructive) {
                // Future: clearHistory()
            } label: {
                Label("Clear All History", systemImage: "trash")
            }
            .controlSize(.small)

            Text("This clears locally stored trend data but does not affect current quota snapshots.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .padding()
    }

    private var aboutTab: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.pie.fill")
                .font(.system(size: 32))
                .foregroundStyle(.tint)

            Text("Quota Monitor")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Version 1.0.0b")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Text("Unsigned beta — for testing only.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            Divider()

            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Privacy")
                        .font(.system(size: 11, weight: .semibold))
                    Text("This app does not collect, save, or transmit any personal data, credentials, conversation content, or project files. All data is stored locally.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
            }

            HStack(spacing: 16) {
                Button("Copy Diagnostic Summary") {
                    copyDiagnosticSummary()
                }
                .controlSize(.small)

                Button("Show Data Folder") {
                    showDataFolder()
                }
                .controlSize(.small)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func copyDiagnosticSummary() {
        var lines: [String] = []
        lines.append("Quota Monitor v1.0.0b")
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("")
        for id in ProviderID.allCases {
            lines.append("\(id.displayName):")
            if let snap = store.snapshots[id] {
                lines.append("  Status: \(snap.freshness.displayName)")
                lines.append("  Sampled: \(snap.observedAt.formatted())")
                if let primary = snap.primaryWindow {
                    lines.append("  Primary: \(primary.type.displayName) \(primary.remainingPercent.map { "\(Int($0.rounded()))%" } ?? "N/A")")
                }
            } else {
                lines.append("  Not loaded")
            }
        }
        let summary = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
    }

    private func showDataFolder() {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        if let support = paths.first {
            let appSupport = support.appendingPathComponent("AIQuota")
            try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: appSupport.path)
        }
    }
}
