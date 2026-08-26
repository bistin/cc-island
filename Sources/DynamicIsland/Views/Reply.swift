import DynamicIslandCore
import SwiftUI

// MARK: - Pending Action Dots

/// Hints that more `.action` events are queued behind the current one,
/// without a numeric badge. Up to three dots.
struct PendingActionDots: View {
    let count: Int
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<min(count, 3), id: \.self) { _ in
                Circle()
                    .fill(Color.white.opacity(pulse ? 0.85 : 0.45))
                    .frame(width: 4, height: 4)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

// MARK: - Permission Action Buttons (shared by notch + capsule expanded)

struct PermissionActionButtons: View {
    @ObservedObject var stateManager: IslandStateManager
    let suggestedRule: PermissionRuleSuggestion?
    let eventID: UUID
    let tty: String?
    /// Carried alongside the tty so the jump can reach a pane on a named tmux
    /// server, the same way a tap on the ears does.
    let tmuxSocket: String?

    @AppStorage(clickToTerminalKey, store: dynamicIslandUserDefaults)
    private var clickToTerminalEnabled = true

    private var expired: Bool { stateManager.currentEventExpired }

    /// Whether to draw the jump row at all — the visibility half of the same policy the action
    /// half already asks `DynamicIslandCore` about. Kept in step by calling the same function,
    /// rather than by two people remembering to change both.
    private var canJumpToTab: Bool {
        guard !expired else { return false }
        return shouldTapJumpToTerminal(
            style: .other,   // the row is drawn beside a decision; the decision is not what it acts on
            hasReplyMode: false,
            hasTTY: !(tty ?? "").isEmpty,
            clickToTerminalEnabled: clickToTerminalEnabled
        ) && TerminalActivator.hasRunningTerminal()
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button(action: {
                    stateManager.respond("allow", eventID: eventID)
                }) {
                    Text("Allow")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(red: 0.2, green: 0.5, blue: 1.0))
                        )
                }
                .buttonStyle(.plain)
                .disabled(expired)

                Button(action: {
                    stateManager.respond("deny", eventID: eventID)
                }) {
                    Text("Deny")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.white.opacity(0.1))
                        )
                }
                .buttonStyle(.plain)
                .disabled(expired)
            }
            .opacity(expired ? 0.5 : 1)

            // "Always allow" — sends the rule back to Claude Code so the
            // pattern lands in `localSettings.permissions.allow` and future
            // matching invocations stop asking. Amber tint (not the Allow
            // blue) signals "this is a persistent preference" rather than a
            // primary yes/no action, and shrinks the tap target to reduce
            // mis-taps on the adjacent Allow button.
            if let rule = suggestedRule {
                Button(action: {
                    stateManager.respond("allow", rule: rule, eventID: eventID)
                }) {
                    HStack(spacing: 8) {
                        Spacer()
                        Text("🔓").font(.system(size: 11))
                        Text("Always allow")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(red: 1.0, green: 0.75, blue: 0.4))
                        Text(rule.ruleContent)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Color(red: 1.0, green: 0.82, blue: 0.59).opacity(0.75))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(Color(red: 1.0, green: 0.67, blue: 0.24).opacity(0.14))
                    )
                }
                .buttonStyle(.plain)
                .disabled(expired)
                .opacity(expired ? 0.5 : 1)
            }

            // Jump to the terminal tab that's awaiting this decision —
            // gives the user a discoverable alternative to clicking the
            // ear, which isn't obvious. Doesn't resolve the permission;
            // user still has to come back and pick Allow/Deny.
            if canJumpToTab, let tty {
                Button(action: {
                    stateManager.focusTerminal(tty: tty, tmuxSocket: tmuxSocket)
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "terminal")
                            .font(.system(size: 11))
                        Text("Jump to terminal tab")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.white.opacity(0.85))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(Color.white.opacity(0.08))
                    )
                }
                .buttonStyle(.plain)
            }

            if expired {
                Text("Reply window expired — dismiss and re-trigger to respond.")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.55))
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }
}

// MARK: - Quick Reply Buttons (shared by notch + capsule expanded)

/// Phase 1 of #20. Renders one button per `labels` entry; tap POSTs the
/// label as the response body to the long-polling Stop hook, which then
/// emits `decision:block + reason:<label>` to Claude. Layout and tinting
/// mirror `PermissionActionButtons` so the two buttons rows feel
/// consistent across action and reminder events.
///
/// Caller is expected to cap `labels` at 3 entries / 20 chars each
/// (enforced server-side in `LocalServer.processEvent` already).
struct QuickReplyButtons: View {
    @ObservedObject var stateManager: IslandStateManager
    let labels: [String]
    let eventID: UUID

    private var expired: Bool { stateManager.currentEventExpired }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                ForEach(labels, id: \.self) { label in
                    Button(action: {
                        stateManager.respond(label, eventID: eventID)
                    }) {
                        Text(label)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.95))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.white.opacity(0.12))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(expired)
                }
            }
            .opacity(expired ? 0.5 : 1)

            if expired {
                Text("Reply window expired — dismiss and re-trigger to respond.")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.55))
            }
        }
    }
}

// MARK: - Inline Reply Field (#36, #20 Phase 2)

/// Single-line text input + Send for free-form Stop replies. Dumb
/// component — the parent decides whether to render it (gated on the
/// `enableInlineReply` UserDefault) and feeds the eventID. Submit
/// posts the typed string through the same `setResponse` channel
/// quick-reply buttons use; the hook emits
/// `decision: block + reason: <text>` so Claude treats it as the
/// next instruction.
struct InlineReplyField: View {
    @ObservedObject var stateManager: IslandStateManager
    let eventID: UUID
    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("Reply…", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .focused($focused)
                .onSubmit(submit)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.08))
                )

            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(
                        text.trimmingCharacters(in: .whitespaces).isEmpty
                            ? Color.white.opacity(0.3)
                            : Color(red: 0.4, green: 0.7, blue: 1.0)
                    )
            }
            .buttonStyle(.plain)
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .onAppear {
            // Panel uses `.nonactivatingPanel` and is not key by default,
            // so the TextField stays visible but rejects keystrokes.
            // Promote the panel to key + focus the field together so the
            // first character lands without an extra click.
            stateManager.panel?.makeKey()
            focused = true
        }
    }

    private func submit() {
        // The trim and the empty guard moved into `respond`; the field is only cleared when the
        // answer actually went, so an expired one leaves the typing where the user can see it.
        if stateManager.respond(text, eventID: eventID) { text = "" }
    }
}
