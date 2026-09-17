import Foundation

/// The one place that wires the toggle and hanja handlers and starts monitoring.
///
/// Two call sites used to do this separately — app launch and the Settings
/// accessibility check — and only the launch one registered `onTapFailed`, so a
/// tap armed from Settings ran with no IOKit fallback and died silently when the
/// system disabled it.
///
/// Arming is idempotent, which is what makes a late permission grant recoverable.
/// The launch-time poll gives up after two minutes; granting Accessibility after
/// that used to leave the toggle key dead for the rest of the session, with the
/// Settings UI reporting everything as fine.
public enum KeyMonitoring {
    /// Wire every handler and start the event tap. Safe to call repeatedly.
    /// - Returns: whether the CGEventTap itself started; the IOKit fallback takes
    ///   over when it did not.
    @discardableResult
    public static func arm() -> Bool {
        guard IOKitManager.hasAccessibilityPermission() else {
            DebugLogger.log("KeyMonitoring: no Accessibility permission, not arming")
            return false
        }

        RightCommandSuppressor.shared.onToggle = {
            InputModeCoordinator.shared.requestToggle(source: .customKey)
        }
        RightCommandSuppressor.shared.onHanjaLookup = {
            PriTypeInputController.sharedComposer.triggerHanjaLookup()
        }
        RightCommandSuppressor.shared.onTapFailed = {
            DebugLogger.log("KeyMonitoring: CGEventTap failed repeatedly — activating IOKit fallback")
            startIOKitFallback()
        }

        let started = RightCommandSuppressor.shared.start()
        if started {
            DebugLogger.log("KeyMonitoring: CGEventTap started")
        } else {
            DebugLogger.log("KeyMonitoring: CGEventTap did not start — IOKit takes over as primary")
            startIOKitFallback()
        }
        return started
    }

    /// Re-arm when monitoring is not already running. Cheap enough for a focus
    /// change, and the reason a permission granted after launch takes effect.
    public static func armIfNeeded() {
        guard !RightCommandSuppressor.shared.isRunning else { return }
        arm()
    }

    private static func startIOKitFallback() {
        IOKitManager.shared.onRightCommandToggle = {
            InputModeCoordinator.shared.requestToggle(source: .iokitFallback)
        }
        IOKitManager.shared.onRightOptionHanja = {
            PriTypeInputController.sharedComposer.triggerHanjaLookup()
        }
        IOKitManager.shared.start()
    }
}
