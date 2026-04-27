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

    private var expired: Bool { stateManager.currentEventExpired }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button(action: {
                    stateManager.server?.setResponse("allow", eventID: eventID)
                    stateManager.dismiss()
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
                    stateManager.server?.setResponse("deny", eventID: eventID)
                    stateManager.dismiss()
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
                    stateManager.server?.setResponse("allow", rule: rule, eventID: eventID)
                    stateManager.dismiss()
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
                        stateManager.server?.setResponse(label, eventID: eventID)
                        stateManager.dismiss()
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
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        stateManager.server?.setResponse(trimmed, eventID: eventID)
        stateManager.dismiss()
    }
}
