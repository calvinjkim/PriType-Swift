import Testing
import CoreGraphics
@testable import PriTypeCore

// MARK: - ToggleKeyEventClassifier Tests
//
// Contract: CONTRACT.md §3-1 (C1–C11). These exercise the pure decision logic the
// CGEventTap callback delegates to, so the 한/영 전환키 path is covered without a
// tap, Accessibility permission, or a running IMK server.

@Suite("ToggleKeyEventClassifier")
struct ToggleKeyEventClassifierTests {

    // Virtual key codes
    private let rightCommand: Int64 = 54
    private let leftCommand: Int64 = 55
    private let rightOption: Int64 = 61
    private let capsLock: Int64 = 57
    private let space: Int64 = 49
    private let keyC: Int64 = 8
    private let f13: Int64 = 105

    // Flag bits as CGEventTap reports them
    private let commandFlag = CGEventFlags.maskCommand.rawValue
    private let optionFlag = CGEventFlags.maskAlternate.rawValue
    private let controlFlag = CGEventFlags.maskControl.rawValue
    private let alphaShiftFlag = CGEventFlags.maskAlphaShift.rawValue
    /// Device-specific "right Command" bit macOS sets alongside `maskCommand`.
    private let deviceRightCommandBit: UInt64 = 0x10
    /// Device-specific "right Option" bit macOS sets alongside `maskAlternate`.
    private let deviceRightOptionBit: UInt64 = 0x40

    private let defaultToggle = KeyBinding.defaultToggle   // 우측 Command
    private let defaultHanja = KeyBinding.defaultHanja     // 우측 Option

    // MARK: - C1–C4: 우측 Command press / release / held

    @Test("C1: Right Command press fires the toggle and swallows the event")
    func rightCommandPressToggles() {
        var classifier = ToggleKeyEventClassifier()
        let action = classifier.classify(
            kind: .flagsChanged,
            keyCode: rightCommand,
            flags: commandFlag | deviceRightCommandBit,
            toggle: defaultToggle,
            hanja: defaultHanja
        )
        #expect(action == .toggle)
        #expect(classifier.toggleModifierIsDown)
    }

    @Test("C2: Right Command release is swallowed and clears the held state")
    func rightCommandReleaseSuppressed() {
        var classifier = ToggleKeyEventClassifier()
        _ = classifier.classify(kind: .flagsChanged, keyCode: rightCommand, flags: commandFlag | deviceRightCommandBit, toggle: defaultToggle, hanja: defaultHanja)
        let release = classifier.classify(kind: .flagsChanged, keyCode: rightCommand, flags: 0, toggle: defaultToggle, hanja: defaultHanja)
        #expect(release == .suppress)
        #expect(!classifier.toggleModifierIsDown)
    }

    @Test("C3: A key typed while Right Command is held has the Command bit stripped")
    func keyWhileToggleHeldStripsModifier() {
        var classifier = ToggleKeyEventClassifier()
        _ = classifier.classify(kind: .flagsChanged, keyCode: rightCommand, flags: commandFlag | deviceRightCommandBit, toggle: defaultToggle, hanja: defaultHanja)
        let action = classifier.classify(kind: .keyDown, keyCode: keyC, flags: commandFlag, toggle: defaultToggle, hanja: defaultHanja)
        // Both bits: leaving the device bit behind still reads as right Command.
        #expect(action == .stripModifier(commandFlag | deviceRightCommandBit))
    }

    @Test("C4: A key typed after Right Command was released passes through untouched")
    func keyAfterToggleReleasedPassesThrough() {
        var classifier = ToggleKeyEventClassifier()
        _ = classifier.classify(kind: .flagsChanged, keyCode: rightCommand, flags: commandFlag | deviceRightCommandBit, toggle: defaultToggle, hanja: defaultHanja)
        _ = classifier.classify(kind: .flagsChanged, keyCode: rightCommand, flags: 0, toggle: defaultToggle, hanja: defaultHanja)
        let action = classifier.classify(kind: .keyDown, keyCode: keyC, flags: 0, toggle: defaultToggle, hanja: defaultHanja)
        #expect(action == .passThrough)
    }

    @Test("Repeated flagsChanged while Right Command stays held does not re-toggle")
    func heldToggleDoesNotRepeat() {
        var classifier = ToggleKeyEventClassifier()
        _ = classifier.classify(kind: .flagsChanged, keyCode: rightCommand, flags: commandFlag | deviceRightCommandBit, toggle: defaultToggle, hanja: defaultHanja)
        let again = classifier.classify(kind: .flagsChanged, keyCode: rightCommand, flags: commandFlag | deviceRightCommandBit, toggle: defaultToggle, hanja: defaultHanja)
        #expect(again == .passThrough)
    }

    // MARK: - C5–C7: Caps Lock and the other Command key

    @Test("C5: Right Command toggles even while Caps Lock (alpha shift) is engaged")
    func rightCommandTogglesWithCapsLockEngaged() {
        var classifier = ToggleKeyEventClassifier()
        let action = classifier.classify(
            kind: .flagsChanged,
            keyCode: rightCommand,
            flags: commandFlag | deviceRightCommandBit | alphaShiftFlag,
            toggle: defaultToggle,
            hanja: defaultHanja
        )
        #expect(action == .toggle)
    }

    @Test("C6: Caps Lock itself is never a PriType key — always passes through")
    func capsLockPassesThrough() {
        var classifier = ToggleKeyEventClassifier()
        let pressed = classifier.classify(kind: .flagsChanged, keyCode: capsLock, flags: alphaShiftFlag, toggle: defaultToggle, hanja: defaultHanja)
        let released = classifier.classify(kind: .flagsChanged, keyCode: capsLock, flags: 0, toggle: defaultToggle, hanja: defaultHanja)
        #expect(pressed == .passThrough)
        #expect(released == .passThrough)
    }

    @Test("C7: Left Command is not the toggle key under the default binding")
    func leftCommandPassesThrough() {
        var classifier = ToggleKeyEventClassifier()
        let action = classifier.classify(kind: .flagsChanged, keyCode: leftCommand, flags: commandFlag, toggle: defaultToggle, hanja: defaultHanja)
        #expect(action == .passThrough)
        #expect(!classifier.toggleModifierIsDown)
    }

    // MARK: - C8–C9: Hanja key

    @Test("C8: Right Option press fires Hanja lookup; its release is swallowed")
    func rightOptionHanja() {
        var classifier = ToggleKeyEventClassifier()
        let press = classifier.classify(kind: .flagsChanged, keyCode: rightOption, flags: optionFlag | deviceRightOptionBit, toggle: defaultToggle, hanja: defaultHanja)
        let release = classifier.classify(kind: .flagsChanged, keyCode: rightOption, flags: 0, toggle: defaultToggle, hanja: defaultHanja)
        #expect(press == .hanja)
        #expect(release == .suppress)
    }

    @Test("C9: When hanja and toggle share a key code, the toggle wins and hanja never fires")
    func toggleWinsTieWithHanja() {
        var classifier = ToggleKeyEventClassifier()
        let sameKeyHanja = KeyBinding(keyCode: rightCommand, modifiers: 0, displayName: "우측 Command")
        let action = classifier.classify(kind: .flagsChanged, keyCode: rightCommand, flags: commandFlag | deviceRightCommandBit, toggle: defaultToggle, hanja: sameKeyHanja)
        #expect(action == .toggle)
        #expect(!classifier.hanjaModifierIsDown)
    }

    // MARK: - C10–C11: Regular-key toggles

    @Test("C10: Control + Space combo toggles only when Control is held")
    func controlSpaceCombo() {
        var classifier = ToggleKeyEventClassifier()
        let combo = ToggleKey.controlSpace.asKeyBinding
        let withControl = classifier.classify(kind: .keyDown, keyCode: space, flags: controlFlag, toggle: combo, hanja: defaultHanja)
        let withoutControl = classifier.classify(kind: .keyDown, keyCode: space, flags: 0, toggle: combo, hanja: defaultHanja)
        #expect(withControl == .toggle)
        #expect(withoutControl == .passThrough)
    }

    @Test("C11: A single regular key (F13) bound as toggle fires on keyDown")
    func singleRegularKeyToggle() {
        var classifier = ToggleKeyEventClassifier()
        let f13Binding = KeyBinding(keyCode: f13, modifiers: 0, displayName: "F13")
        let action = classifier.classify(kind: .keyDown, keyCode: f13, flags: 0, toggle: f13Binding, hanja: defaultHanja)
        #expect(action == .toggle)
    }

    @Test("Ordinary typing with no toggle key involved passes through")
    func ordinaryTypingPassesThrough() {
        var classifier = ToggleKeyEventClassifier()
        let plain = classifier.classify(kind: .keyDown, keyCode: keyC, flags: 0, toggle: defaultToggle, hanja: defaultHanja)
        let shortcut = classifier.classify(kind: .keyDown, keyCode: keyC, flags: commandFlag, toggle: defaultToggle, hanja: defaultHanja)
        #expect(plain == .passThrough)
        #expect(shortcut == .passThrough)
    }
}
