import AppKit
import DynamicIslandCore
import IslandHookCore
import SwiftUI

/// Settings panel with three tabs (#41, #45):
///
/// - **General** — inline-reply toggle + tunable Stop / dwell timings.
/// - **Appearance** — source-colour palette (Claude / Copilot / Codex).
/// - **Hooks** — per-provider auto-sync toggles + reinstall buttons.
///
/// All three tabs use `@AppStorage(... store: dynamicIslandUserDefaults)`
/// for live UI binding. Hook-side propagation (env-var injection into
/// `~/.claude/settings.json`) requires reinstalling the hooks; the Hooks
/// tab carries the button.
struct SettingsView: View {
    @ObservedObject var stateManager: IslandStateManager

    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceTab()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            HooksTab()
                .tabItem { Label("Hooks", systemImage: "link") }
            DiagnosticsTab(stateManager: stateManager)
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .padding()
        .frame(minWidth: 480, minHeight: 440)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @AppStorage(enableInlineReplyKey, store: dynamicIslandUserDefaults)
    private var inlineReplyEnabled = false

    @AppStorage(clickToTerminalKey, store: dynamicIslandUserDefaults)
    private var clickToTerminalEnabled = true

    @AppStorage(stopReplyTimeoutKey, store: dynamicIslandUserDefaults)
    private var stopReplyTimeoutSeconds: Double = StopReplyTimeoutSeconds

    @AppStorage(screenFollowerDwellKey, store: dynamicIslandUserDefaults)
    private var screenFollowerDwellMs: Double = 200

    var body: some View {
        Form {
            Section {
                Toggle("Click island to focus terminal tab", isOn: $clickToTerminalEnabled)
                Text("Tapping a non-decision event jumps to the Terminal.app or iTerm2 tab running the matching session. Falls back to expanding the event when the tab can't be located. Turn off to keep the legacy expand-on-tap behaviour.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Click behaviour").font(.headline)
            }

            Section {
                Toggle("Inline reply for Stop events", isOn: $inlineReplyEnabled)
                Text("Lets you reply to Claude's free-form questions directly from the island. Toggling this changes the UI immediately, but the hook side only picks it up after reinstalling Claude Code hooks (see Hooks tab).")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Reply").font(.headline)
            }

            Section {
                HStack {
                    Text("Stop reply timeout")
                    Spacer()
                    TextField(
                        "",
                        value: $stopReplyTimeoutSeconds,
                        format: .number.precision(.fractionLength(0...1))
                    )
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    Text("seconds")
                        .foregroundColor(.secondary)
                }
                Text("How long the island waits for your reply before falling back to Claude's default Stop behaviour. Reinstall hooks to apply.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Text("Screen follower dwell")
                    Spacer()
                    TextField(
                        "",
                        value: $screenFollowerDwellMs,
                        format: .number.precision(.fractionLength(0))
                    )
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    Text("ms")
                        .foregroundColor(.secondary)
                }
                Text("How long the cursor must rest on a different screen before the island moves there. Applies on the next cursor move; no reinstall needed.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Timings").font(.headline)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Appearance

private struct AppearanceTab: View {
    @AppStorage(claudeColorHexKey, store: dynamicIslandUserDefaults)
    private var claudeHex = defaultClaudeColorHex

    @AppStorage(copilotColorHexKey, store: dynamicIslandUserDefaults)
    private var copilotHex = defaultCopilotColorHex

    @AppStorage(codexColorHexKey, store: dynamicIslandUserDefaults)
    private var codexHex = defaultCodexColorHex

    var body: some View {
        Form {
            Section {
                ColorPicker("Claude Code", selection: hexBinding($claudeHex), supportsOpacity: false)
                ColorPicker("GitHub Copilot", selection: hexBinding($copilotHex), supportsOpacity: false)
                ColorPicker("OpenAI Codex", selection: hexBinding($codexHex), supportsOpacity: false)
                HStack {
                    Spacer()
                    Button("Reset to defaults") {
                        claudeHex = defaultClaudeColorHex
                        copilotHex = defaultCopilotColorHex
                        codexHex = defaultCodexColorHex
                    }
                }
            } header: {
                Text("Source colours").font(.headline)
            } footer: {
                Text("Drives the source-tinted stripe on each ear and the project-source dot. Colour change applies to the next event the island shows.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

/// Adapter — exposes a `@Binding<String>` (a `#RRGGBB` hex stored in
/// UserDefaults) as a `Binding<Color>` so SwiftUI's `ColorPicker` can
/// drive it directly. Round-trips through sRGB component extraction
/// via `NSColor` so non-sRGB picks (e.g. `Display P3` from the
/// system colour panel) flatten cleanly.
private func hexBinding(_ source: Binding<String>) -> Binding<Color> {
    Binding<Color>(
        get: {
            let rgb = parseHexColor(source.wrappedValue) ?? RGB(r: 1, g: 1, b: 1)
            return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
        },
        set: { newColor in
            let ns = NSColor(newColor).usingColorSpace(.sRGB) ?? NSColor.white
            let rgb = RGB(
                r: Double(ns.redComponent),
                g: Double(ns.greenComponent),
                b: Double(ns.blueComponent)
            )
            source.wrappedValue = encodeHexColor(rgb)
        }
    )
}

// MARK: - Hooks

private struct HooksTab: View {
    @AppStorage(autoSyncClaudeKey, store: dynamicIslandUserDefaults)
    private var autoSyncClaude = true

    @AppStorage(autoSyncCodexKey, store: dynamicIslandUserDefaults)
    private var autoSyncCodex = true

    @State private var claudeStatus = ReinstallStatus.idle
    @State private var codexStatus = ReinstallStatus.idle

    enum ReinstallStatus: Equatable {
        case idle, installed, alreadyCurrent, failed(String)
    }

    var body: some View {
        Form {
            claudeSection
            codexSection
            copilotSection
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var claudeSection: some View {
        Section {
            Toggle("Auto-sync at launch", isOn: $autoSyncClaude)
            Text("Re-deploys the hook binary if the bundled version changed. Off skips the launch-time check; you can still reinstall here on demand.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Reinstall Claude Code Hooks") {
                    claudeStatus = doReinstall(target: .claudeCode, isClaude: true)
                }
                statusLabel(claudeStatus)
            }
        } header: {
            Text("Claude Code").font(.headline)
        }
    }

    @ViewBuilder
    private var codexSection: some View {
        Section {
            Toggle("Auto-sync at launch", isOn: $autoSyncCodex)
            Text("Only takes effect once Codex hooks have been installed (CLI: `--install-codex-hooks`). With sync on, the deployed binary is refreshed on each app launch.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Reinstall Codex Hooks") {
                    codexStatus = doReinstall(target: .codex, isClaude: false)
                }
                statusLabel(codexStatus)
            }
        } header: {
            Text("Codex").font(.headline)
        }
    }

    @ViewBuilder
    private var copilotSection: some View {
        Section {
            Text("Copilot hooks are scoped to a single repository. Install or update from Terminal:")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("DynamicIsland --install-copilot-hooks <repo-path>")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(.vertical, 2)
        } header: {
            Text("Copilot").font(.headline)
        }
    }

    @ViewBuilder
    private func statusLabel(_ status: ReinstallStatus) -> some View {
        switch status {
        case .idle:
            EmptyView()
        case .installed:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.caption)
        case .alreadyCurrent:
            Label("Already up to date", systemImage: "checkmark.circle")
                .foregroundColor(.secondary)
                .font(.caption)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
                .font(.caption)
                .lineLimit(2)
        }
    }

    /// Fire `HookInstaller.install` and translate to a status enum. For
    /// Claude, also flip the legacy `hookInstallChoice` UserDefault to
    /// `installed` so the next launch's prompt path stays consistent
    /// with what the user just confirmed via this button.
    private func doReinstall(target: HookInstaller.Target, isClaude: Bool) -> ReinstallStatus {
        let result = HookInstaller.install(target: target)
        if isClaude, case .installed = result {
            UserDefaults.standard.set("installed", forKey: hookInstallChoiceKey)
        }
        switch result {
        case .installed: return .installed
        case .alreadyCurrent: return .alreadyCurrent
        case .failed(let reason): return .failed(reason)
        case .skipped(let message): return .failed(message)
        case .removed, .notInstalled: return .idle
        }
    }
}
