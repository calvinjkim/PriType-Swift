import Testing
import CoreGraphics
@testable import PriTypeCore

// MARK: - Left vs right modifier identity

/// The toggle key is one physical key. CGEventFlags' generic bits (.maskCommand
/// and friends) are shared by the left and right key, so a release of the bound
/// key cannot be told from the other side still being held: the "toggle held"
/// latch never clears and every later key event has its modifier stripped
/// (Cmd+C inserts a literal "c"). Detection needs the device-dependent bits.
@Suite("ModifierMask")
struct ModifierMaskTests {
    // keyCodes: 54 right / 55 left Command, 61 right / 58 left Option,
    // 62 right / 59 left Control, 60 right / 56 left Shift.
    private let pairs: [(right: Int64, left: Int64, name: String)] = [
        (54, 55, "Command"),
        (61, 58, "Option"),
        (62, 59, "Control"),
        (60, 56, "Shift")
    ]

    @Test("Left and right of one modifier have distinct device masks")
    func deviceMasksDiffer() {
        for pair in pairs {
            let r = RightCommandSuppressor.deviceModifierMask(for: pair.right)
            let l = RightCommandSuppressor.deviceModifierMask(for: pair.left)
            #expect(r.rawValue != 0, "\(pair.name): right device mask must exist")
            #expect(l.rawValue != 0, "\(pair.name): left device mask must exist")
            #expect(r != l, "\(pair.name): left and right must not share a device bit")
        }
    }

    @Test("A device mask isolates its own side")
    func devicePressIsolated() {
        // Left Command held, right Command not: the right key must read as up.
        let leftCommandHeld = RightCommandSuppressor.deviceModifierMask(for: 55)
            .union(.maskCommand)
        #expect(!leftCommandHeld.contains(RightCommandSuppressor.deviceModifierMask(for: 54)),
                "right Command must read as up while only left Command is held")
        #expect(leftCommandHeld.contains(.maskCommand),
                "the generic bit is still set, which is why it cannot be used for detection")
    }

    @Test("Generic masks stay shared, for stripping the modifier off a key event")
    func genericMasksShared() {
        for pair in pairs {
            #expect(RightCommandSuppressor.modifierMask(for: pair.right)
                    == RightCommandSuppressor.modifierMask(for: pair.left),
                    "\(pair.name): the generic mask is deliberately side-agnostic")
        }
    }

    @Test("An unbound key has no device mask")
    func unknownKeyCode() {
        #expect(RightCommandSuppressor.deviceModifierMask(for: 0).rawValue == 0)
    }
}
