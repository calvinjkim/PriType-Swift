import Foundation
import Cocoa
import ApplicationServices

/// Primary toggle key handler using CGEventTap.
///
/// ## Role
/// Intercepts the user-configured 한/영 전환키 and 한자키 at the system level using
/// CGEventTap to provide instant language mode switching.
///
/// ## Decision vs. side effects
/// WHAT to do with an event is decided by `ToggleKeyEventClassifier` (pure, unit
/// tested). This class only performs the side effects: swallowing the event,
/// rewriting flags, and firing `onToggle` / `onHanjaLookup` on the main queue.
///
/// ## Dynamic Key Binding
/// Reads `ConfigurationManager.toggleKeyBinding` / `hanjaKeyBinding` on every event
/// (cached in memory there — no JSON decode on the hot path). Users can configure
/// any modifier key or key combination via the Settings UI.
///
/// ## Relationship with IOKitManager
/// `ToggleKeyMonitor` owns startup and fallback. When the system disables this tap
/// repeatedly, `onTapFailed` fires and the monitor STOPS this tap before starting
/// `IOKitManager`, so exactly one monitor is ever live.
///
/// ## Key Features
/// - **Instant toggle**: Switches on key press, not release
/// - **Modifier stripping**: When toggle modifier is held, removes its modifier from other keys
/// - **Dynamic binding**: Supports any key via KeyBinding struct
public final class RightCommandSuppressor: @unchecked Sendable {

    // Singleton - accessed from CGEventTap callback context
    public static let shared = RightCommandSuppressor()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Whether the event tap is currently running
    public var isRunning: Bool { eventTap != nil }

    /// Callback for toggle
    public var onToggle: (@Sendable () -> Void)?

    /// Callback for Hanja lookup
    public var onHanjaLookup: (@Sendable () -> Void)?

    /// Pure decision logic. Holds the modifier press/release edge state.
    private var classifier = ToggleKeyEventClassifier()

    /// Debounce timer for Hanja trigger to prevent double-fire
    private var lastHanjaTriggerTime: DispatchTime = .init(uptimeNanoseconds: 0)

    /// Track CGEventTap disable events for auto-recovery
    private var tapDisableCount = 0
    private var lastTapDisableTime: CFAbsoluteTime = 0
    private let maxTapDisableRetries = 3
    private let tapDisableResetInterval: CFAbsoluteTime = 60  // Reset counter after 60s of stability

    /// Callback for when CGEventTap permanently fails and IOKit should take over
    public var onTapFailed: (@Sendable () -> Void)?

    /// Whether recording mode is active (for Key Recorder in settings)


    private init() {}

    // MARK: - Start/Stop

    /// Start monitoring toggle keys
    /// - Returns: `true` if CGEventTap was created successfully, `false` otherwise
    @discardableResult
    public func start() -> Bool {
        guard eventTap == nil else {
            DebugLogger.log("RightCommandSuppressor: Already running")
            return true
        }

        guard IOKitManager.hasAccessibilityPermission() else {
            DebugLogger.log("RightCommandSuppressor: No Accessibility permission")
            return false
        }

        // Monitor flagsChanged AND keyDown events
        let eventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)

        // Create event tap
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { proxy, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let suppressor = Unmanaged<RightCommandSuppressor>.fromOpaque(refcon).takeUnretainedValue()
                return suppressor.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let eventTap = eventTap else {
            DebugLogger.log("RightCommandSuppressor: Failed to create event tap")
            return false
        }

        // Add to run loop
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        let config = ConfigurationManager.shared
        DebugLogger.log("RightCommandSuppressor: Started (toggle=\(config.toggleKeyBinding.displayName), hanja=\(config.hanjaKeyBinding.displayName))")
        return true
    }

    /// Stop monitoring
    public func stop() {
        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        eventTap = nil
        runLoopSource = nil
        // A restarted tap must not inherit a stale "modifier is held" edge or the
        // disable counter from the previous incarnation.
        classifier = ToggleKeyEventClassifier()
        tapDisableCount = 0
        DebugLogger.log("RightCommandSuppressor: Stopped")
    }

    // MARK: - Event Handling

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            return handleTapDisabled(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        // Key recording mode — capture the next key press for settings UI

        let kind: ToggleKeyEventClassifier.Kind
        if type == .flagsChanged {
            kind = .flagsChanged
        } else if type == .keyDown {
            kind = .keyDown
        } else {
            return Unmanaged.passUnretained(event)
        }

        let config = ConfigurationManager.shared
        let toggleBinding = config.toggleKeyBinding
        let hanjaBinding = config.hanjaKeyBinding
        let action = classifier.classify(
            kind: kind,
            keyCode: keyCode,
            flags: event.flags.rawValue,
            toggle: toggleBinding,
            hanja: hanjaBinding
        )

        switch action {
        case .passThrough:
            return Unmanaged.passUnretained(event)
        case .suppress:
            return nil
        case .toggle:
            DebugLogger.log("RightCommandSuppressor: Toggle key (\(toggleBinding.displayName)) - TOGGLE")
            triggerToggle()
            return nil
        case .hanja:
            // Modifier flagsChanged can double-fire; a regular keyDown does not.
            if kind == .keyDown || passesHanjaDebounce() {
                DebugLogger.log("RightCommandSuppressor: Hanja key (\(hanjaBinding.displayName)) - HANJA")
                triggerHanjaLookup()
            }
            return nil
        case .stripModifier(let mask):
            // The toggle modifier is held: make this key plain input, not a shortcut.
            event.flags = CGEventFlags(rawValue: event.flags.rawValue & ~mask)
            DebugLogger.log("RightCommandSuppressor: Key with toggle modifier - stripped modifier (normal input)")
            return Unmanaged.passUnretained(event)
        }
    }

    /// The system disabled the tap (callback too slow, or user input). Re-enable a
    /// few times; past the limit hand over to the IOKit fallback and LEAVE THIS TAP
    /// DISABLED. Re-enabling it here would leave TWO live monitors — the tap toggles
    /// on key-down, IOKit on key-up — so one 우측 Command press would toggle twice
    /// and land back on the original mode ("전환키가 안 먹는다").
    private func handleTapDisabled(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let now = CFAbsoluteTimeGetCurrent()

        // Reset counter if stable for 60+ seconds
        if now - lastTapDisableTime > tapDisableResetInterval {
            tapDisableCount = 0
        }
        lastTapDisableTime = now
        tapDisableCount += 1

        if tapDisableCount >= maxTapDisableRetries, let callback = onTapFailed {
            DebugLogger.log("RightCommandSuppressor: Tap disabled \(tapDisableCount) times, handing over to IOKit fallback")
            DispatchQueue.main.async {
                callback()
            }
            return Unmanaged.passUnretained(event)
        }

        DebugLogger.log("RightCommandSuppressor: Tap disabled (\(tapDisableCount)/\(maxTapDisableRetries)), re-enabling")
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    // MARK: - Helpers

    /// Ignore a hanja trigger that follows the previous one within 500ms.
    private func passesHanjaDebounce() -> Bool {
        let now = DispatchTime.now()
        let elapsedMs = (now.uptimeNanoseconds - lastHanjaTriggerTime.uptimeNanoseconds) / 1_000_000
        if elapsedMs < 500 {
            DebugLogger.log("RightCommandSuppressor: Hanja key DEBOUNCED (\(elapsedMs)ms)")
            return false
        }
        lastHanjaTriggerTime = now
        return true
    }

    private func triggerToggle() {
        let callback = onToggle
        // Hop to the main run loop and let the toggle settle there. This matches
        // the proven v2.6.5 baseline: first-key stability comes from the single
        // internal state machine (`HangulComposer.inputMode` with no async TIS
        // source selection), NOT from running the toggle synchronously inside the
        // CGEventTap callback. Keeping IMK commit / keyboard-override work off the
        // tap callback also protects against `kCGEventTapDisabledByTimeout`.
        DispatchQueue.main.async {
            callback?()
        }
    }

    private func triggerHanjaLookup() {
        let callback = onHanjaLookup
        DispatchQueue.main.async {
            callback?()
        }
    }
}
