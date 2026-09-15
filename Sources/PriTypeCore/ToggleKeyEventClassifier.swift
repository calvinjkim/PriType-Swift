import Foundation

// MARK: - ToggleKeyEventClassifier

/// Pure decision logic for the system-level 한/영 전환키 · 한자키 monitor.
///
/// `RightCommandSuppressor` feeds raw `CGEvent` facts in (event kind, virtual key
/// code, modifier flag bits) and performs the side effects for the returned
/// `Action` (swallow the event, fire a callback, rewrite flags). Only the
/// edge-detection state for modifier keys lives here, so the entire toggle-key
/// decision path is unit-testable without a CGEventTap or Accessibility permission.
///
/// ## Policy (single source of truth)
/// The configured toggle binding is ALWAYS live. macOS "Caps Lock으로 입력 소스
/// 전환" is deliberately NOT an input here: the two paths never share a key event
/// (Caps Lock, key code 57, is rejected as a PriType binding in
/// `ConfigurationManager.toggleKeyBinding`), and both end in the same
/// `HangulComposer.inputMode` through `PriTypeInputController`, so there is nothing
/// to arbitrate. Gating the custom key on that macOS setting silently disabled
/// 우측 Command for every user with the (default-on) Caps Lock switch.
public struct ToggleKeyEventClassifier: Sendable {

    /// The CGEvent kinds the monitor subscribes to.
    public enum Kind: Sendable {
        case flagsChanged
        case keyDown
    }

    /// What the monitor must do with the event.
    public enum Action: Equatable, Sendable {
        /// Deliver the event unchanged.
        case passThrough
        /// Swallow the event (e.g. the release of the toggle modifier).
        case suppress
        /// Fire the 한/영 toggle and swallow the event.
        case toggle
        /// Fire Hanja lookup and swallow the event.
        case hanja
        /// Deliver the event with these `CGEventFlags` bits cleared, so a key typed
        /// while the toggle modifier is held is plain input, not a shortcut.
        case stripModifier(UInt64)
    }

    /// Caps Lock's virtual key code. Never a PriType key: macOS owns it.
    private static let capsLockKeyCode: Int64 = 57

    private(set) var toggleModifierIsDown = false
    private(set) var hanjaModifierIsDown = false

    public init() {}

    /// Classify one event.
    /// - Parameters:
    ///   - kind: `.flagsChanged` for modifier keys, `.keyDown` for everything else.
    ///   - keyCode: `CGEvent` virtual key code (`kCGKeyboardEventKeycode`).
    ///   - flags: `CGEventFlags.rawValue` of the event.
    ///   - toggle: The user's 한/영 전환키 binding.
    ///   - hanja: The user's 한자 입력키 binding.
    public mutating func classify(
        kind: Kind,
        keyCode: Int64,
        flags: UInt64,
        toggle: KeyBinding,
        hanja: KeyBinding
    ) -> Action {
        switch kind {
        case .flagsChanged:
            return classifyFlagsChanged(keyCode: keyCode, flags: flags, toggle: toggle, hanja: hanja)
        case .keyDown:
            return classifyKeyDown(keyCode: keyCode, flags: flags, toggle: toggle, hanja: hanja)
        }
    }

    // MARK: - flagsChanged (modifier keys)

    private mutating func classifyFlagsChanged(
        keyCode: Int64,
        flags: UInt64,
        toggle: KeyBinding,
        hanja: KeyBinding
    ) -> Action {
        if keyCode == Self.capsLockKeyCode {
            return .passThrough
        }

        // Modifier-only toggle binding (e.g. 우측 Command): fire on the press edge,
        // swallow the release, ignore repeated flag changes while held.
        if toggle.isModifierKey && toggle.isModifierOnly && keyCode == toggle.keyCode {
            let isPressed = (flags & toggle.modifierFlagMask) != 0
            if isPressed && !toggleModifierIsDown {
                toggleModifierIsDown = true
                return .toggle
            }
            if !isPressed && toggleModifierIsDown {
                toggleModifierIsDown = false
                return .suppress
            }
            return .passThrough
        }

        // Modifier-only hanja binding (e.g. 우측 Option). The toggle key wins a tie.
        if hanja.isModifierKey && hanja.isModifierOnly && keyCode == hanja.keyCode && keyCode != toggle.keyCode {
            let isPressed = (flags & hanja.modifierFlagMask) != 0
            if isPressed && !hanjaModifierIsDown {
                hanjaModifierIsDown = true
                return .hanja
            }
            if !isPressed && hanjaModifierIsDown {
                hanjaModifierIsDown = false
                return .suppress
            }
        }

        return .passThrough
    }

    // MARK: - keyDown (regular keys)

    private func classifyKeyDown(
        keyCode: Int64,
        flags: UInt64,
        toggle: KeyBinding,
        hanja: KeyBinding
    ) -> Action {
        // Regular-key toggle: a single key (e.g. F13) or a combo (e.g. Control + Space).
        if keyCode == toggle.keyCode && !toggle.isModifierKey {
            if toggle.isModifierOnly || Self.hasRequiredModifiers(flags: flags, required: toggle.modifiers) {
                return .toggle
            }
        }

        // Regular-key hanja binding. The toggle key wins a tie.
        if keyCode == hanja.keyCode && !hanja.isModifierKey && keyCode != toggle.keyCode {
            if hanja.isModifierOnly || Self.hasRequiredModifiers(flags: flags, required: hanja.modifiers) {
                return .hanja
            }
        }

        // A key typed while the toggle modifier is held is plain input, not a shortcut.
        if toggleModifierIsDown && toggle.isModifierKey {
            return .stripModifier(toggle.modifierFlagMask)
        }

        return .passThrough
    }

    private static func hasRequiredModifiers(flags: UInt64, required: UInt64) -> Bool {
        (flags & required) == required
    }
}
