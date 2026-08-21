import AppKit
import DynamicIslandCore
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
        if args.contains("--login-item-status") { printLoginItemStatus(); exit(0) }
        if let tty = flagValue(in: args, after: "--reveal-tty") {
            runRevealCLI(tty: tty, socket: flagValue(in: args, after: "--tmux-socket"))
            exit(0)
        }
        if args.contains("--compat-table") { print(Compat.markdown(), terminator: ""); exit(0) }
        if args.contains("--help") || args.contains("-h") { printUsage(); exit(0) }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // Hide from dock
        app.run()
    }

    /// Diagnostic: run the same focus routes a click on the island runs, and say which answered.
    ///
    /// Deliberately an action rather than a status, unlike `--login-item-status`: what it does is
    /// exactly what the user was going to do by clicking, and the point is to be able to check it
    /// without one.
    private static func runRevealCLI(tty: String, socket: String? = nil) {
        guard let decoded = decodeTTY(from: tty) else {
            FileHandle.standardError.write(Data("not a tty this app will accept: \(tty)\n".utf8))
            print("expected /dev/ttys<digits> or /dev/pts/<digits>")
            exit(1)
        }
        // Validated with the same parser the hook uses, so the CLI cannot reach
        // further than a real payload could.
        let checked = socket.flatMap { tmuxSocketPath(fromTMUXEnv: $0) }
        if socket != nil, checked == nil {
            FileHandle.standardError.write(Data("not a socket path: \(socket!)\n".utf8))
            exit(1)
        }
        print("reveal \(decoded)\(checked.map { " on \($0)" } ?? "")")
        print(TerminalActivator.revealSynchronously(tty: decoded, tmuxSocket: checked))
    }

    /// The value after a flag, or nil when the flag is absent or has nothing after it.
    private static func flagValue(in args: [String], after flag: String) -> String? {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
        let value = args[idx + 1]
        return value.hasPrefix("--") ? nil : value
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

    /// Read-only view of what macOS thinks about launching us at login.
    /// Read-only on purpose: the registration itself stays a deliberate user
    /// action in Settings, so a stray CLI invocation can't add a login item.
    /// Reports the same status the Settings toggle renders — run it from
    /// inside the bundle (`DynamicIsland.app/Contents/MacOS/DynamicIsland`),
    /// since a bare build has no login item to report on.
    private static func printLoginItemStatus() {
        let controller = LoginItemController.shared
        print("Launch at login: \(controller.status)")
        if let message = controller.presentation.message {
            print("  \(message)")
        }
    }

    private static func runInstallCLI(target: HookInstaller.Target) {
        switch HookInstaller.syncIfOutdated(target: target) {
        case .installed:
            print("Installed \(target.displayName) hooks:")
            print("  script:   \(target.deployedHookURL.path)")
            print("  settings: \(target.settingsURL.path)")
            if case .codex = target {
                print("Next: open /hooks in Codex and trust the Dynamic Island hooks.")
            }
        case .alreadyCurrent:
            print("\(target.displayName) hooks already up to date.")
            if case .codex = target {
                print("If they have not run yet, open /hooks in Codex and verify they are trusted.")
            }
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
          --install-codex-hooks                Install Codex hooks (~/.codex/hooks.json); migrates
                                               legacy [features].codex_hooks to the canonical hooks key.
          --uninstall-codex-hooks              Remove Codex hooks from ~/.codex/hooks.json.
          --login-item-status                  Report whether macOS launches the island at login
                                               (set it in Settings → General → Startup).
          --reveal-tty <tty>                   Focus the terminal pane owning that tty, the same way
                                               clicking the island does, and say which route answered.
                                               For diagnosing "clicking jumps to the wrong tab".
          --tmux-socket <path>                 With --reveal-tty: address a tmux server started with
                                               `tmux -L name` / `-S path` instead of the default one.
          --compat-table                       Print what this build assumes about Claude Code, tmux
                                               and macOS, and what breaks when each changes.
                                               Generates docs/compatibility.md.
          --help, -h                           Show this help.
        """)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var panel: IslandPanel!
    var stateManager = IslandStateManager()
    var server: LocalServer!
    var statusItem: NSStatusItem!

    private let screenFollower = ScreenFollower()
    private var screenChangeObserver: NSObjectProtocol?

    // Strongly retained — without this property, the window deallocates
    // on first close and cmd-, would break (#41 review).
    private var settingsWindowController: SettingsWindowController?

    // hookInstallChoiceKey lives at module scope (HookInstaller.swift)
    // so SettingsView's HooksTab can share the same string.

    func applicationDidFinishLaunching(_ notification: Notification) {
        // First line in the file, so everything below it has a day, a build and
        // a pid to belong to.
        Log.banner(
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        )
        // #41: register UserDefaults defaults so unset reads return the
        // documented values rather than 0 / false at the bare API level.
        // Per-call sites still use `positiveDouble(...)` as a belt-and-
        // suspenders fallback — covers the case where the user explicitly
        // sets a key to 0.
        dynamicIslandUserDefaults.register(defaults: [
            stopReplyTimeoutKey: StopReplyTimeoutSeconds,
            permissionTimeoutKey: PermissionTimeoutSeconds,
            screenFollowerDwellKey: 200.0,
            // #45: source colours, default to today's hardcoded palette
            claudeColorHexKey: defaultClaudeColorHex,
            copilotColorHexKey: defaultCopilotColorHex,
            codexColorHexKey: defaultCodexColorHex,
            // #45: per-provider auto-sync at launch. Defaults match
            // pre-#45 behaviour (Claude on, Codex on, Copilot off).
            autoSyncClaudeKey: true,
            autoSyncCodexKey: true,
            autoSyncCopilotKey: false,
            // Click-to-focus-terminal-tab: on by default; users can opt
            // back into the legacy expand-on-click via Settings.
            clickToTerminalKey: true,
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
            title: "CLI Island",
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
        let header = NSMenuItem(title: "CLI Island v\(version)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettings),
            keyEquivalent: ",")
        settings.keyEquivalentModifierMask = [.command]
        menu.addItem(settings)

        // Same state as Settings → General → Startup, one click closer.
        // Its checkmark is refreshed in `menuNeedsUpdate` because macOS can
        // change it behind our back (System Settings → Login Items).
        launchAtLoginItem = NSMenuItem(
            title: "Open at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: "")
        menu.addItem(launchAtLoginItem!)

        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Quit CLI Island",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        menu.addItem(quit)
        // Manual enabling: `menuNeedsUpdate` decides whether "Open at Login"
        // is clickable, and auto-enabling would overwrite that verdict.
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: - Launch at login

    /// Retained so `menuNeedsUpdate` can restate its checkmark.
    private var launchAtLoginItem: NSMenuItem?

    @objc private func toggleLaunchAtLogin() {
        let controller = LoginItemController.shared
        controller.setEnabled(!controller.presentation.isOn)
        refreshLaunchAtLoginItem()

        // `requiresApproval` can't be cleared from here — say so rather than
        // leaving a checkmark that silently refuses to move. The alert carries
        // the same two escape hatches Settings shows, since the menu has no
        // room for buttons of its own.
        if controller.presentation.showsSystemSettingsButton {
            let alert = NSAlert()
            alert.messageText = "Enable in System Settings"
            alert.informativeText = controller.presentation.message ?? ""
            alert.addButton(withTitle: "Open Login Items")
            if controller.presentation.showsUnregisterButton {
                alert.addButton(withTitle: "Remove Login Item")
            }
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                controller.openSystemSettings()
            case .alertSecondButtonReturn where controller.presentation.showsUnregisterButton:
                controller.setEnabled(false)
                refreshLaunchAtLoginItem()
            default:
                break
            }
        }
    }

    private func refreshLaunchAtLoginItem() {
        let controller = LoginItemController.shared
        controller.refresh()
        let state = controller.presentation
        launchAtLoginItem?.state = state.isOn ? .on : .off
        // A vetoed item is deliberately non-interactive as a toggle, but the
        // menu is the only place that explains why — greying it out would hide
        // the explanation and the Remove button along with it.
        launchAtLoginItem?.isEnabled =
            state.isInteractive || state.showsSystemSettingsButton
    }

    @objc func menuNeedsUpdate(_ menu: NSMenu) {
        refreshLaunchAtLoginItem()
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

    private func maybePromptForHookInstall() {
        switch UserDefaults.standard.string(forKey: hookInstallChoiceKey) {
        case "installed":
            // #45: gate the launch-time sync behind the per-provider
            // auto-sync UserDefault so a user can opt out from the
            // Settings panel.
            if dynamicIslandUserDefaults.bool(forKey: autoSyncClaudeKey) {
                // Says whether the deployed hook was rewritten. An upgrade that
                // silently failed to redeploy leaves the old binary in place and
                // every symptom pointing at the app instead.
                Log.write("hooks(claude): \(HookInstaller.syncIfOutdated(target: .claudeCode))")
            }
        case "declined":
            break
        default:
            showInstallPrompt()
        }

        // Codex hooks are installed explicitly via CLI/menu, but once
        // present they need the same binary drift repair as Claude
        // hooks after app upgrades. Same per-provider gate.
        if HookInstaller.hasExistingInstall(target: .codex),
           dynamicIslandUserDefaults.bool(forKey: autoSyncCodexKey) {
            Log.write("hooks(codex): \(HookInstaller.syncIfOutdated(target: .codex))")
        }
    }

    private func showInstallPrompt() {
        let alert = NSAlert()
        alert.messageText = "Configure Claude Code hooks?"
        alert.informativeText = """
            CLI Island needs Claude Code hooks to receive tool events.

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
            UserDefaults.standard.set("installed", forKey: hookInstallChoiceKey)
            reportInstallResult(result, target: .claudeCode)
        case .alertThirdButtonReturn:   // Never
            UserDefaults.standard.set("declined", forKey: hookInstallChoiceKey)
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
