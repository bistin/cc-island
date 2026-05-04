import DynamicIslandCore
import SwiftUI

// MARK: - Diagnostics & Tools tab

/// Fourth tab in the Settings panel (#49). Two sections:
///
/// - **Diagnostics** — read-only "is the install healthy?" surface:
///   server reachability, per-target hook install status, and a
///   ring buffer of the last 20 events `pushEvent` was asked to
///   handle (including dropped ones, useful for diagnosis).
/// - **Tools** — three self-test buttons that exercise the full
///   chain so the user can sanity-check the wiring without
///   spinning up a real Claude session.
struct DiagnosticsTab: View {
    @ObservedObject var stateManager: IslandStateManager

    @State private var sendStatus = SelfTest.Outcome?.none
    @State private var permissionStatus = SelfTest.Outcome?.none
    @State private var codexStatus = SelfTest.Outcome?.none

    var body: some View {
        Form {
            Section {
                serverStatusRow
            } header: {
                Text("Server").font(.headline)
            }

            Section {
                hookRow(label: "Claude Code", target: .claudeCode)
                hookRow(label: "Codex", target: .codex)
                Text("Copilot hooks are per-repository — not visible from the global app launch path.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Hooks").font(.headline)
            }

            Section {
                toolButton(
                    title: "Send Test Event",
                    status: sendStatus
                ) {
                    Task { sendStatus = await SelfTest.sendTestEvent() }
                }
                toolButton(
                    title: "Test Permission Flow",
                    status: permissionStatus
                ) {
                    Task { permissionStatus = await SelfTest.sendTestPermissionFlow() }
                }
                toolButton(
                    title: "Test Codex Hook",
                    status: codexStatus,
                    disabled: !codexInstalled
                ) {
                    Task {
                        codexStatus = await SelfTest.testCodexHook(
                            deployedHookURL: HookInstaller.Target.codex.deployedHookURL
                        )
                    }
                }
            } header: {
                Text("Tools").font(.headline)
            } footer: {
                Text("Each button fires a payload through the same code path a real hook would. Look for the result on the island as well as the inline status here.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                if stateManager.recentEvents.isEmpty {
                    Text("No events yet — fire a Tools button or wait for hook traffic.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(stateManager.recentEvents.reversed()) { entry in
                        recentRow(entry)
                    }
                }
            } header: {
                Text("Recent events (last \(stateManager.recentEvents.count))")
                    .font(.headline)
            } footer: {
                Text("Last 20 attempts captured at the top of `pushEvent`. Dropped events show up here too — useful for diagnosing 'why didn't this surface?' questions.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Subviews

    @ViewBuilder
    private var serverStatusRow: some View {
        HStack {
            Text("HTTP listener")
            Spacer()
            Text("127.0.0.1:9423")
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.secondary)
        }
        Text("Hooks POST events to this address. The Tools section below sanity-checks the path.")
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func hookRow(label: String, target: HookInstaller.Target) -> some View {
        let status = HookInstaller.installStatus(target: target)
        HStack {
            Text(label)
            Spacer()
            statusBadge(status)
        }
        Text(target.deployedHookURL.path)
            .font(.system(.caption, design: .monospaced))
            .foregroundColor(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }

    @ViewBuilder
    private func statusBadge(_ status: HookInstaller.InstallStatus) -> some View {
        switch status {
        case .notInstalled:
            Label("Not installed", systemImage: "circle.slash")
                .font(.caption)
                .foregroundColor(.secondary)
        case .installedAndCurrent:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundColor(.green)
        case .installedButOutdated:
            Label("Out of sync", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundColor(.orange)
        }
    }

    @ViewBuilder
    private func toolButton(
        title: String,
        status: SelfTest.Outcome?,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            Button(title, action: action)
                .disabled(disabled)
            outcomeLabel(status)
            Spacer()
        }
    }

    @ViewBuilder
    private func outcomeLabel(_ outcome: SelfTest.Outcome?) -> some View {
        switch outcome {
        case .none:
            EmptyView()
        case .success(let msg):
            Label(msg, systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.caption)
                .lineLimit(2)
        case .failure(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
                .font(.caption)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private func recentRow(_ entry: RecentEvent) -> some View {
        HStack(spacing: 8) {
            Text(Self.timeFormatter.string(from: entry.timestamp))
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
            Text(entry.title)
                .font(.caption)
                .lineLimit(1)
            Text(entry.style.rawValue)
                .font(.caption2)
                .foregroundColor(entry.style.color)
            Spacer()
            dispositionBadge(entry.disposition)
        }
    }

    @ViewBuilder
    private func dispositionBadge(_ disposition: EventDisposition) -> some View {
        let (text, color): (String, Color) = {
            switch disposition {
            case .showImmediately: return ("shown", .green)
            case .queueAsAction: return ("queued", .blue)
            case .mergeProgress: return ("merged", .gray)
            case .dropTransient: return ("dropped", .red)
            }
        }()
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                Capsule().fill(color.opacity(0.18))
            )
            .foregroundColor(color)
    }

    private var codexInstalled: Bool {
        FileManager.default.fileExists(
            atPath: HookInstaller.Target.codex.deployedHookURL.path
        )
    }

    /// Static so we don't allocate a new formatter on every body /
    /// row re-render — `DateFormatter.init` is non-trivial.
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
