import SwiftUI
import IslandHookCore

/// First slice of #41 (README roadmap item 11). One "General" tab with:
///
/// - Inline-reply toggle — gates Phase 2 of #20 on the app side.
///   Hook-side env propagation requires reinstalling Claude Code hooks
///   (helper text + button below makes this explicit, no implicit
///   "magic" reinstall on toggle change).
/// - Stop reply timeout — long-poll horizon on the hook side. Must be
///   reinstalled to propagate; the same Reinstall button covers it.
/// - Screen follower dwell — reactive at runtime, no reinstall needed.
struct SettingsView: View {
    @ObservedObject var stateManager: IslandStateManager

    @AppStorage(enableInlineReplyKey, store: dynamicIslandUserDefaults)
    private var inlineReplyEnabled = false

    @AppStorage(stopReplyTimeoutKey, store: dynamicIslandUserDefaults)
    private var stopReplyTimeoutSeconds: Double = StopReplyTimeoutSeconds

    @AppStorage(screenFollowerDwellKey, store: dynamicIslandUserDefaults)
    private var screenFollowerDwellMs: Double = 200

    @State private var reinstallStatus: ReinstallStatus = .idle

    enum ReinstallStatus: Equatable {
        case idle, installed, alreadyCurrent, failed(String)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Inline reply for Stop events", isOn: $inlineReplyEnabled)
                Text("Lets you reply to Claude's free-form questions directly from the island. After toggling, click Reinstall below for the change to reach the hook.")
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
                Text("How long the island waits for your reply before falling back to Claude's default Stop behaviour. Reinstall hooks for changes to apply.")
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

            Section {
                HStack {
                    Button("Reinstall Claude Code Hooks") { reinstall() }
                    statusLabel
                    Spacer()
                }
            } header: {
                Text("Hooks").font(.headline)
            } footer: {
                Text("Required after toggling Inline reply or changing Stop reply timeout — the values reach the hook process via env vars in the hook command, written into ~/.claude/settings.json on install.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 460, minHeight: 340)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch reinstallStatus {
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

    private func reinstall() {
        let result = HookInstaller.install(target: .claudeCode)
        switch result {
        case .installed:
            reinstallStatus = .installed
        case .alreadyCurrent:
            reinstallStatus = .alreadyCurrent
        case .failed(let reason):
            reinstallStatus = .failed(reason)
        case .skipped(let message):
            reinstallStatus = .failed(message)
        case .removed, .notInstalled:
            reinstallStatus = .idle
        }
    }
}
