import Foundation

// MARK: - ToggleKeyMonitor

/// Single owner of toggle/hanja key monitoring startup and fallback.
///
/// Exactly ONE monitor delivers key events at any time. The CGEventTap
/// (`RightCommandSuppressor`) is primary; `IOKitManager` takes over only when the
/// system disables the tap repeatedly, and the tap is stopped FIRST. Two live
/// monitors would fire the toggle twice per press (the tap on key-down, IOKit on
/// key-up) and land back on the original mode — observed as "우측 Command가 안 먹는다".
///
/// Both launch (`main.swift`) and the Settings accessibility flow call `start()`;
/// the callback wiring lives here so it cannot drift between the two entry points.
public enum ToggleKeyMonitor {

    /// Start monitoring if Accessibility permission is available. Idempotent: calling
    /// it while a monitor is already running re-wires the callbacks and returns `true`.
    /// - Returns: `true` if some monitor is now running.
    @discardableResult
    public static func start() -> Bool {
        guard IOKitManager.hasAccessibilityPermission() else {
            DebugLogger.log("ToggleKeyMonitor: no Accessibility permission, not starting")
            return false
        }

        wireCallbacks()

        // After a hand-over IOKit is the active monitor; never resurrect the tap
        // beside it (two live monitors toggle twice per press).
        if IOKitManager.shared.isRunning {
            DebugLogger.log("ToggleKeyMonitor: IOKit already active, leaving CGEventTap stopped")
            return true
        }

        if RightCommandSuppressor.shared.start() {
            DebugLogger.log("ToggleKeyMonitor: CGEventTap is the active monitor")
            return true
        }

        DebugLogger.log("ToggleKeyMonitor: CGEventTap unavailable, IOKit is the active monitor")
        return IOKitManager.shared.start()
    }

    private static func wireCallbacks() {
        let tap = RightCommandSuppressor.shared
        tap.onToggle = {
            InputModeCoordinator.shared.requestToggle(source: .customKey)
        }
        tap.onHanjaLookup = {
            PriTypeInputController.sharedComposer.triggerHanjaLookup()
        }
        tap.onTapFailed = {
            handOverToIOKit()
        }

        let iokit = IOKitManager.shared
        iokit.onRightCommandToggle = {
            InputModeCoordinator.shared.requestToggle(source: .iokitFallback)
        }
        iokit.onRightOptionHanja = {
            PriTypeInputController.sharedComposer.triggerHanjaLookup()
        }
    }

    /// Runs on the main queue (dispatched by the suppressor). Stops the tap BEFORE
    /// starting IOKit so there is never a moment with two live monitors.
    private static func handOverToIOKit() {
        RightCommandSuppressor.shared.stop()
        if IOKitManager.shared.start() {
            DebugLogger.log("ToggleKeyMonitor: handed over to IOKit fallback")
            return
        }
        // Last resort: no monitor at all is worse than a flaky tap.
        DebugLogger.log("ToggleKeyMonitor: IOKit fallback failed, restarting CGEventTap")
        RightCommandSuppressor.shared.start()
    }
}
