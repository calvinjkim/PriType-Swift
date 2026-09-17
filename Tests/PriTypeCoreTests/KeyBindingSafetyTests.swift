import Testing
import CoreGraphics
import Foundation
@testable import PriTypeCore

// MARK: - A binding must not swallow a key the user needs

/// The event tap consumes the bound key globally. A bare printable key therefore
/// removes that key from the whole system with no way back: binding Space stops
/// the space bar everywhere, including in this settings window, so the only
/// recovery is `defaults write`. A modifier key alone, or a regular key with a
/// modifier, or a function key, are all safe.
@Suite("KeyBindingSafety")
struct KeyBindingSafetyTests {
    private func binding(_ keyCode: Int64, _ modifiers: UInt64 = 0) -> KeyBinding {
        KeyBinding(keyCode: keyCode, modifiers: modifiers, displayName: "test")
    }

    @Test("A bare printable or essential key is rejected")
    func barePrintableRejected() {
        for (code, name) in [(Int64(49), "Space"), (36, "Return"), (48, "Tab"),
                             (51, "Delete"), (0, "A"), (29, "0"), (53, "Escape")] {
            #expect(!binding(code).isSafeAsBinding, "\(name) alone must be rejected")
        }
    }

    @Test("The same key with a modifier is fine")
    func withModifierAccepted() {
        #expect(binding(49, CGEventFlags.maskControl.rawValue).isSafeAsBinding)
        #expect(binding(0, CGEventFlags.maskCommand.rawValue).isSafeAsBinding)
    }

    @Test("A modifier key alone is fine")
    func modifierAloneAccepted() {
        for code in [Int64(54), 55, 58, 61, 59, 62, 56, 60] {
            #expect(binding(code).isSafeAsBinding, "modifier keyCode \(code) must be allowed")
        }
    }

    @Test("A bare function key is fine")
    func bareFunctionKeyAccepted() {
        for code in [Int64(105), 107, 113, 106, 122, 120] {   // F13-F16, F1, F2
            #expect(binding(code).isSafeAsBinding, "function keyCode \(code) must be allowed")
        }
    }

    @Test("Caps Lock and Fn stay unsupported")
    func capsLockAndFnRejected() {
        #expect(!binding(57).isSafeAsBinding)
        #expect(!binding(63).isSafeAsBinding)
    }

    @Test("An already-saved unsafe binding is replaced, not handed back")
    func persistedUnsafeBindingIsSanitized() {
        // A user who bound Space before this guard existed cannot type a space
        // anywhere, so they cannot fix it in the UI either. Reading must repair it.
        #expect(KeyBinding.sanitizedToggle(binding(49)) == .defaultToggle)
        #expect(KeyBinding.sanitizedToggle(binding(36)) == .defaultToggle)
    }

    @Test("A safe persisted binding is returned unchanged")
    func persistedSafeBindingSurvives() {
        let controlSpace = binding(49, CGEventFlags.maskControl.rawValue)
        #expect(KeyBinding.sanitizedToggle(controlSpace) == controlSpace)
        #expect(KeyBinding.sanitizedToggle(binding(54)) == binding(54))
    }
}
