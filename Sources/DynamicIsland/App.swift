import AppKit
import IslandHookCore
import SwiftUI

@main
struct DynamicIslandApp {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--install-hooks")   { runInstallCLI(target: .claudeCode);   exit(0) }
        if args.contains("--uninstall-hooks") { runUninstallCLI(target: .claudeCode); exit(0) }
        if let repo = copilotRepoPath(in: args, after: "--install-copilot-hooks") {
            runInstallCLI(target: .copilot(repoPath: repo)); exit(0)
        }
        if let repo = copilotRepoPath(in: args, after: "--uninstall-copilot-hooks") {
            runUninstallCLI(target: .copilot(repoPath: repo)); exit(0)
        }
        if args.contains("--install-codex-hooks") {
            runInstallCLI(target: .codex); exit(0)
        }
        if args.contains("--uninstall-codex-hooks") {
            runUninstallCLI(target: .codex); exit(0)
        }
        if args.contains("--help") || args.contains("-h") { printUsage(); exit(0) }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // Hide from dock
        app.run()
    }

    /// Returns the repo path for the Copilot CLI flag, or nil if the flag isn't present.
    /// Accepts an optional path after the flag; defaults to CWD. Rejects missing/invalid dirs.
    private static func copilotRepoPath(in args: [String], after flag: String) -> URL? {
        guard let idx = args.firstIndex(of: flag) else { return nil }
        let rawPath: String
        if idx + 1 < args.count, !args[idx + 1].hasPrefix("--") {
            rawPath = args[idx + 1]
        } else {
            rawPath = FileManager.default.currentDirectoryPath
        }
        let url = URL(fileURLWithPath: rawPath).standardized
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else {
            FileHandle.standardError.write(Data("Not a directory: \(url.path)\n".utf8))
            exit(1)
        }
        return url
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

          (no options)                         Run the app normally.
          --install-hooks                      Install Claude Code hooks (~/.claude/settings.json).
          --uninstall-hooks                    Remove Claude Code hooks.
          --install-copilot-hooks [repoPath]   Install Copilot hooks to {repoPath}/.github/hooks/hooks.json
                                               (defaults to current directory).
          --uninstall-copilot-hooks [repoPath] Remove Copilot hooks from that repo.
          --install-codex-hooks                Install Codex hooks (~/.codex/hooks.json) and enable
                                               [features].codex_hooks in ~/.codex/config.toml.
          --uninstall-codex-hooks              Remove Codex hooks from ~/.codex/hooks.json.
          --help, -h                           Show this help.
        """)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: IslandPanel!
    var stateManager = IslandStateManager()
    var server: LocalServer!
    var statusItem: NSStatusItem!

    private let screenFollower = ScreenFollower()
    private var screenChangeObserver: NSObjectProtocol?

    // Strongly retained — without this property, the window deallocates
    // on first close and cmd-, would break (#41 review).
    private var settingsWindowController: SettingsWindowController?

    private static let hookChoiceKey = "hookInstallChoice"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // #41: register UserDefaults defaults so unset reads return the
        // documented values rather than 0 / false at the bare API level.
        // Per-call sites still use `positiveDouble(...)` as a belt-and-
        // suspenders fallback — covers the case where the user explicitly
        // sets a key to 0.
        dynamicIslandUserDefaults.register(defaults: [
            stopReplyTimeoutKey: StopReplyTimeoutSeconds,
            screenFollowerDwellKey: 200.0,
        ])

        panel = IslandPanel(stateManager: stateManager)
        panel.show()

        server = LocalServer(stateManager: stateManager)
        server.start()
        stateManager.server = server

        // Multi-screen: panel follows the cursor's screen.
        stateManager.panel = panel
        screenFollower.onTargetChanged = { [weak panel] screen in
            panel?.relocate(to: screen)
        }
        screenFollower.start()
        // The initial panel was anchored to NSScreen.main in IslandPanel.init.
        // If the cursor is already on a different screen at launch, relocate
        // immediately instead of waiting for the first user mouse move.
        screenFollower.forceEvaluateNow()

        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.screenFollower.handleScreenTopologyChange()
            // Cocoa auto-reparents orphaned windows, so `relocate(to:)` may
            // see no work to do. Force-refresh the notch metrics anyway.
            self?.panel?.refreshLayoutForCurrentScreen()
        }

        NotificationMonitor.shared.start(stateManager: stateManager)

        setupStatusBarItem()

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

    // MARK: - Menu bar status item

    private func setupStatusBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = makeIslandIcon()

        let menu = NSMenu()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let header = NSMenuItem(title: "Dynamic Island v\(version)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettings),
            keyEquivalent: ",")
        settings.keyEquivalentModifierMask = [.command]
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Reinstall Claude Code Hooks",
            action: #selector(reinstallHooks),
            keyEquivalent: ""))
        menu.addItem(NSMenuItem(
            title: "Reinstall Codex Hooks",
            action: #selector(reinstallCodexHooks),
            keyEquivalent: ""))
        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Quit Dynamic Island",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    /// A horizontal pill — the Dynamic Island silhouette in compact form.
    /// Drawn inside a 22×22 canvas so the click target matches the menu bar's
    /// standard hit area, with the pill itself centered for visual proportion.
    /// Template-rendered so it adapts to light/dark menu bars.
    private func makeIslandIcon() -> NSImage {
        let canvas = NSSize(width: 22, height: 22)
        let pillSize = NSSize(width: 18, height: 8)
        let image = NSImage(size: canvas, flipped: false) { _ in
            let pillRect = NSRect(
                x: (canvas.width  - pillSize.width)  / 2,
                y: (canvas.height - pillSize.height) / 2,
                width: pillSize.width,
                height: pillSize.height
            )
            let path = NSBezierPath(
                roundedRect: pillRect,
                xRadius: pillSize.height / 2,
                yRadius: pillSize.height / 2
            )
            NSColor.labelColor.setFill()
            path.fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    @objc private func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController.make(
                stateManager: stateManager
            )
        }
        settingsWindowController?.present()
    }

    @objc private func reinstallHooks() {
        let result = HookInstaller.install(target: .claudeCode)
        reportInstallResult(result, target: .claudeCode)
        if case .installed = result {
            UserDefaults.standard.set("installed", forKey: Self.hookChoiceKey)
        }
    }

    @objc private func reinstallCodexHooks() {
        let result = HookInstaller.install(target: .codex)
        reportInstallResult(result, target: .codex)
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

        // Codex hooks are installed explicitly via CLI/menu, but once present
        // they need the same binary drift repair as Claude hooks after app
        // upgrades.
        if HookInstaller.hasExistingInstall(target: .codex) {
            _ = HookInstaller.syncIfOutdated(target: .codex)
        }
    }

    private func showInstallPrompt() {
        let alert = NSAlert()
        alert.messageText = "Configure Claude Code hooks?"
        alert.informativeText = """
            Dynamic Island needs Claude Code hooks to receive tool events.

            Installing will:
              • Copy island-hook to ~/.claude/hooks/dynamic-island-hook
              • Register hook events in ~/.claude/settings.json

            Other tools' hooks will not be touched.

            You can also run this later from a terminal:
              DynamicIsland --install-hooks            (Claude Code)
              DynamicIsland --install-copilot-hooks    (GitHub Copilot)
              DynamicIsland --install-codex-hooks      (OpenAI Codex)
            """
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: "Never")

        switch alert.runModal() {
        case .alertFirstButtonReturn:   // Install
            let result = HookInstaller.install(target: .claudeCode)
            UserDefaults.standard.set("installed", forKey: Self.hookChoiceKey)
            reportInstallResult(result, target: .claudeCode)
        case .alertThirdButtonReturn:   // Never
            UserDefaults.standard.set("declined", forKey: Self.hookChoiceKey)
        default:                        // Skip — ask again next launch
            break
        }
    }

    private func reportInstallResult(_ result: HookInstaller.Result, target: HookInstaller.Target) {
        switch result {
        case .installed:
            stateManager.pushEvent(IslandEvent(
                title: "\(target.displayName) hooks installed",
                subtitle: target.deployedHookURL.path,
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
