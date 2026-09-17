import Foundation
import Cocoa
import ApplicationServices

/// Primary toggle key handler using CGEventTap.
///
/// ## Role
/// Intercepts user-configured toggle and hanja key events at the system level
/// using CGEventTap to provide instant language mode switching.
///
/// ## Dynamic Key Binding
/// Instead of hardcoded keys, this class reads `ConfigurationManager.toggleKeyBinding`
/// and `ConfigurationManager.hanjaKeyBinding` to determine which keys to intercept.
/// Users can configure any modifier key or key combination via the Settings UI.
///
/// ## Relationship with IOKitManager
/// - **Primary handler**: `RightCommandSuppressor` (this class)
/// - **Backup handler**: `IOKitManager`
///
/// This class uses `IOKitManager.hasAccessibilityPermission()` to check permissions.
/// If CGEventTap creation fails (e.g., permission issues), `IOKitManager` takes over.
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
    
    /// Track toggle modifier state
    private var toggleModifierIsDown = false
    
    /// Track hanja modifier state
    private var hanjaModifierIsDown = false
    
    /// Debounce timer for Hanja trigger to prevent double-fire
    private var lastHanjaTriggerTime: DispatchTime = .init(uptimeNanoseconds: 0)

    /// Track Control state for Control+Space
    private var controlIsDown = false
    
    /// Track CGEventTap disable events for auto-recovery
    private var tapDisableCount = 0
    private var lastTapDisableTime: CFAbsoluteTime = 0
    private let maxTapDisableRetries = 3
    private let tapDisableResetInterval: CFAbsoluteTime = 60  // Reset counter after 60s of stability
    
    /// Callback for when CGEventTap permanently fails and IOKit should take over
    public var onTapFailed: (@Sendable () -> Void)?
    
    /// Whether recording mode is active (for Key Recorder in settings)
    
    /// Callback for key recording (settings UI)
    
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
        DebugLogger.log("RightCommandSuppressor: Stopped")
    }
    
    // MARK: - Event Handling
    
    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable tap if disabled by system
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let now = CFAbsoluteTimeGetCurrent()
            
            // Reset counter if stable for 60+ seconds
            if now - lastTapDisableTime > tapDisableResetInterval {
                tapDisableCount = 0
            }
            lastTapDisableTime = now
            tapDisableCount += 1
            
            if tapDisableCount >= maxTapDisableRetries {
                // CGEventTap is repeatedly failing — stop it completely so IOKit
                // is the only handler. Re-enabling here used to leave a zombie
                // tap that double-fired the toggle.
                DebugLogger.log("RightCommandSuppressor: Tap disabled \(tapDisableCount) times, switching to IOKit fallback")
                if let tap = eventTap {
                    CGEvent.tapEnable(tap: tap, enable: false)
                }
                let callback = onTapFailed
                DispatchQueue.main.async { [weak self] in
                    self?.stop()
                    callback?()
                }
                return Unmanaged.passUnretained(event)
            } else {
                DebugLogger.log("RightCommandSuppressor: Tap disabled (\(tapDisableCount)/\(maxTapDisableRetries)), re-enabling")
            }
            
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let config = ConfigurationManager.shared
        let toggleBinding = config.toggleKeyBinding
        let hanjaBinding = config.hanjaKeyBinding
        let priTypeToggleEnabled = !config.capsLockInputSourceSwitchEnabled
        if !priTypeToggleEnabled {
            toggleModifierIsDown = false
        }
        
        // Key recording mode — capture the next key press for settings UI
        
        // Handle flagsChanged (modifier keys)
        if type == .flagsChanged {
            let flags = event.flags
            
            // Track Control key state (for Control+Space combo)
            controlIsDown = flags.contains(.maskControl)

            if keyCode == 57 {
                return Unmanaged.passUnretained(event)
            }
            
            // Dynamic toggle key — modifier key, single-key binding
            if priTypeToggleEnabled && toggleBinding.isModifierKey && toggleBinding.isModifierOnly && keyCode == toggleBinding.keyCode {
                // One physical key: read the device-dependent bit so the other side
                // being held cannot keep this one latched.
                let deviceMask = Self.deviceModifierMask(for: keyCode)
                let detectMask = deviceMask.rawValue != 0 ? deviceMask : Self.modifierMask(for: keyCode)
                let isPressed = flags.contains(detectMask)
                
                if isPressed && !toggleModifierIsDown {
                    // Toggle modifier pressed - toggle immediately!
                    toggleModifierIsDown = true
                    DebugLogger.log("RightCommandSuppressor: Toggle key DOWN (\(toggleBinding.displayName)) - TOGGLE (instant)")
                    triggerToggle()
                    return nil  // Suppress the modifier event
                } else if !isPressed && toggleModifierIsDown {
                    // Toggle modifier released
                    toggleModifierIsDown = false
                    DebugLogger.log("RightCommandSuppressor: Toggle key UP (\(toggleBinding.displayName))")
                    return nil  // Suppress release
                }
            }
            
            // Dynamic hanja key — modifier key, single-key binding (only if different from toggle key)
            if hanjaBinding.isModifierKey && hanjaBinding.isModifierOnly && keyCode == hanjaBinding.keyCode && keyCode != toggleBinding.keyCode {
                // One physical key: read the device-dependent bit so the other side
                // being held cannot keep this one latched.
                let deviceMask = Self.deviceModifierMask(for: keyCode)
                let detectMask = deviceMask.rawValue != 0 ? deviceMask : Self.modifierMask(for: keyCode)
                let isPressed = flags.contains(detectMask)
                
                if isPressed && !hanjaModifierIsDown {
                    hanjaModifierIsDown = true
                    
                    // Debounce: ignore if last trigger was within 500ms
                    let now = DispatchTime.now()
                    let elapsed = now.uptimeNanoseconds - lastHanjaTriggerTime.uptimeNanoseconds
                    let elapsedMs = elapsed / 1_000_000
                    if elapsedMs < 500 {
                        DebugLogger.log("RightCommandSuppressor: Hanja key DEBOUNCED (\(elapsedMs)ms)")
                        return nil
                    }
                    lastHanjaTriggerTime = now
                    
                    DebugLogger.log("RightCommandSuppressor: Hanja key DOWN (\(hanjaBinding.displayName)) - HANJA")
                    triggerHanjaLookup()
                    return nil  // Suppress
                } else if !isPressed && hanjaModifierIsDown {
                    hanjaModifierIsDown = false
                    DebugLogger.log("RightCommandSuppressor: Hanja key UP (\(hanjaBinding.displayName))")
                    return nil  // Suppress release
                }
            }
            
            return Unmanaged.passUnretained(event)
        }
        
        // Handle keyDown
        if type == .keyDown {
            // Regular key (non-modifier) as toggle — single key or combo
            if priTypeToggleEnabled && keyCode == toggleBinding.keyCode && !toggleBinding.isModifierKey {
                if toggleBinding.isModifierOnly {
                    // Single regular key as toggle (e.g., F13, Caps Lock via keyDown)
                    DebugLogger.log("RightCommandSuppressor: Regular key toggle (\(toggleBinding.displayName)) - TOGGLE")
                    triggerToggle()
                    return nil
                } else {
                    // Combo toggle (e.g., Control+Space, Option+G)
                    let requiredFlags = CGEventFlags(rawValue: toggleBinding.modifiers)
                    if Self.modifiersMatch(flags: event.flags, required: requiredFlags) {
                        DebugLogger.log("RightCommandSuppressor: Combo toggle (\(toggleBinding.displayName)) - TOGGLE triggered")
                        triggerToggle()
                        return nil
                    }
                }
            }
            
            // Regular key (non-modifier) as hanja — single key or combo
            if keyCode == hanjaBinding.keyCode && !hanjaBinding.isModifierKey && keyCode != toggleBinding.keyCode {
                if hanjaBinding.isModifierOnly || Self.modifiersMatch(flags: event.flags, required: CGEventFlags(rawValue: hanjaBinding.modifiers)) {
                    DebugLogger.log("RightCommandSuppressor: Regular key hanja (\(hanjaBinding.displayName)) - HANJA")
                    triggerHanjaLookup()
                    return nil
                }
            }
            
            // When toggle modifier is held, strip its modifier from key events
            // This makes keys act as regular character input, not shortcuts
            if priTypeToggleEnabled && toggleModifierIsDown && toggleBinding.isModifierKey {
                var newFlags = event.flags
                newFlags.remove(Self.modifierMask(for: toggleBinding.keyCode))
                newFlags.remove(Self.deviceModifierMask(for: toggleBinding.keyCode))
                event.flags = newFlags
                DebugLogger.log("RightCommandSuppressor: Key with toggle modifier - stripped modifier (normal input)")
                return Unmanaged.passUnretained(event)
            }
        }
        
        return Unmanaged.passUnretained(event)
    }
    
    // MARK: - Helpers
    
    /// Side-agnostic mask for a keyCode. Use this to STRIP a modifier from a key
    /// event; never to decide whether the bound key is down, because the left and
    /// right key of one modifier share these bits.
    static func modifierMask(for keyCode: Int64) -> CGEventFlags {
        switch keyCode {
        case 54, 55: return .maskCommand       // Right/Left Command
        case 61, 58: return .maskAlternate      // Right/Left Option
        case 62, 59: return .maskControl        // Right/Left Control
        case 56, 60: return .maskShift          // Left/Right Shift
        case 57:     return .maskAlphaShift     // Caps Lock
        default:     return CGEventFlags(rawValue: 0)
        }
    }

    /// Device-dependent mask identifying ONE physical modifier key
    /// (IOLLEvent.h NX_DEVICE*KEYMASK). The toggle is a single key, so press and
    /// release must be read from these bits: with the shared bits, releasing the
    /// bound key while the other side is still held leaves the "held" latch set
    /// forever, and the strip branch then eats the modifier off every later key
    /// event — Cmd+C types a literal "c".
    static func deviceModifierMask(for keyCode: Int64) -> CGEventFlags {
        switch keyCode {
        case 55: return CGEventFlags(rawValue: 0x00000008)   // Left Command
        case 54: return CGEventFlags(rawValue: 0x00000010)   // Right Command
        case 58: return CGEventFlags(rawValue: 0x00000020)   // Left Option
        case 61: return CGEventFlags(rawValue: 0x00000040)   // Right Option
        case 59: return CGEventFlags(rawValue: 0x00000001)   // Left Control
        case 62: return CGEventFlags(rawValue: 0x00002000)   // Right Control
        case 56: return CGEventFlags(rawValue: 0x00000002)   // Left Shift
        case 60: return CGEventFlags(rawValue: 0x00000004)   // Right Shift
        default: return CGEventFlags(rawValue: 0)
        }
    }
    
    /// Modifier bits a binding can name. Caps Lock, numeric-pad and function bits
    /// ride along on real events and are not part of a binding.
    private static let bindableModifiers: CGEventFlags = [
        .maskCommand, .maskAlternate, .maskControl, .maskShift
    ]

    /// Whether `flags` names exactly the binding's modifiers.
    ///
    /// A subset test would let a richer combination match: with Control+Space bound,
    /// Control+Command+Space (the macOS Emoji picker) matched too and was swallowed.
    static func modifiersMatch(flags: CGEventFlags, required: CGEventFlags) -> Bool {
        flags.intersection(bindableModifiers) == required.intersection(bindableModifiers)
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
