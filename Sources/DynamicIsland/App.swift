import AppKit
import SwiftUI

@main
struct DynamicIslandApp {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--install-hooks")           { runInstallCLI(target: .claudeCode);   exit(0) }
        if args.contains("--install-copilot-hooks")   { runInstallCLI(target: .copilot);      exit(0) }
        if args.contains("--uninstall-hooks")         { runUninstallCLI(target: .claudeCode); exit(0) }
        if args.contains("--uninstall-copilot-hooks") { runUninstallCLI(target: .copilot);    exit(0) }
        if args.contains("--help") || args.contains("-h") { printUsage(); exit(0) }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // Hide from dock
        app.run()
    }

    private static func runInstallCLI(target: HookInstaller.Target) {
        switch HookInstaller.syncIfOutdated(target: target) {
        case .installed:
            print("Installed \(target.displayName) hooks:")
            print("  script:   \(target.deployedHookURL.path)")
            print("  settings: \(target.settingsURL.path)")
        case .alreadyCurrent:
            print("\(target.displayName) hooks already up to date.")
        case .skipped(let msg):
            FileHandle.standardError.write(Data("Skipped: \(msg)\n".utf8))
            exit(1)
        case .failed(let reason):
            FileHandle.standardError.write(Data("Failed: \(reason)\n".utf8))
            exit(1)
        default:
            break
        }
    }

    private static func runUninstallCLI(target: HookInstaller.Target) {
        switch HookInstaller.uninstall(target: target) {
        case .removed:
            print("Removed \(target.displayName) hooks from \(target.settingsURL.path)")
        case .notInstalled:
            print("No \(target.displayName) hooks to remove.")
        case .failed(let reason):
            FileHandle.standardError.write(Data("Failed: \(reason)\n".utf8))
            exit(1)
        default:
            break
        }
    }

    private static func printUsage() {
        print("""
        Usage: DynamicIsland [options]

          (no options)              Run the app normally.
          --install-hooks           Install Claude Code hooks and exit.
          --uninstall-hooks         Remove Claude Code hooks and exit.
          --install-copilot-hooks   Install GitHub Copilot hooks and exit.
          --uninstall-copilot-hooks Remove GitHub Copilot hooks and exit.
          --help, -h                Show this help.
        """)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: IslandPanel!
    var stateManager = IslandStateManager()
    var server: LocalServer!

    private static let hookChoiceKey = "hookInstallChoice"

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = IslandPanel(stateManager: stateManager)
        panel.show()

        server = LocalServer(stateManager: stateManager)
        server.start()
        stateManager.server = server

        NotificationMonitor.shared.start(stateManager: stateManager)

        // First-run prompt (or silent sync for returning users) — Claude Code only.
        // Copilot setup is CLI-only via --install-copilot-hooks.
        maybePromptForHookInstall()

        stateManager.pushEvent(IslandEvent(
            icon: "🏝️",
            title: "Dynamic Island",
            subtitle: "Ready — listening on port \(server.port)",
            style: .info,
            duration: 3.0
        ))
    }

    private func maybePromptForHookInstall() {
        switch UserDefaults.standard.string(forKey: Self.hookChoiceKey) {
        case "installed":
            _ = HookInstaller.syncIfOutdated(target: .claudeCode)
        case "declined":
            break
        default:
            showInstallPrompt()
        }
    }

    private func showInstallPrompt() {
        let alert = NSAlert()
        alert.messageText = "Configure Claude Code hooks?"
        alert.informativeText = """
            Dynamic Island needs Claude Code hooks to receive tool events.

            Installing will:
              • Copy island-hook.sh to ~/.claude/hooks/
              • Register hook events in ~/.claude/settings.json

            Other tools' hooks will not be touched.

            You can also run this later from a terminal:
              DynamicIsland --install-hooks            (Claude Code)
              DynamicIsland --install-copilot-hooks    (GitHub Copilot)
            """
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: "Never")

        switch alert.runModal() {
        case .alertFirstButtonReturn:   // Install
            let result = HookInstaller.install(target: .claudeCode)
            UserDefaults.standard.set("installed", forKey: Self.hookChoiceKey)
            reportInstallResult(result)
        case .alertThirdButtonReturn:   // Never
            UserDefaults.standard.set("declined", forKey: Self.hookChoiceKey)
        default:                        // Skip — ask again next launch
            break
        }
    }

    private func reportInstallResult(_ result: HookInstaller.Result) {
        switch result {
        case .installed:
            stateManager.pushEvent(IslandEvent(
                title: "Hooks installed",
                subtitle: "~/.claude/hooks/dynamic-island-hook.sh",
                style: .success,
                duration: 4.0
            ))
        case .skipped(let msg), .failed(let msg):
            stateManager.pushEvent(IslandEvent(
                title: "Hook install failed",
                subtitle: msg,
                style: .error,
                duration: 6.0
            ))
        default:
            break
        }
    }
}
