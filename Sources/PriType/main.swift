import Foundation
import InputMethodKit
import Cocoa
import PriTypeCore

let kConnectionName = "PriType_InputString_v2"

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    
    private var hasLaunchedBefore = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugLogger.log("AppDelegate: applicationDidFinishLaunching")
        
        // Initialize IMK Server
        _ = IMKServer(name: kConnectionName, bundleIdentifier: Bundle.main.bundleIdentifier)
        DebugLogger.log("IMKServer initialized")
        
        Task.detached(priority: .utility) {
            InputSourceManager.shared.cleanupStaleInputSources()
        }
        
        // Setup toggle key monitoring
        setupToggleKeyMonitoring()
        
        // Pre-load Hanja dictionary in background for instant lookup
        DispatchQueue.global(qos: .utility).async {
            HanjaManager.shared.loadIfNeeded()
        }
        
        // Setup update notifications
        UpdateNotifier.shared.setup()
        
        // Check for updates in background (respects user preference and 24h throttle)
        if ConfigurationManager.shared.autoUpdateCheckEnabled {
            Task.detached(priority: .utility) {
                let result = await UpdateChecker.shared.checkForUpdatesIfNeeded()
                if case .updateAvailable(let info) = result {
                    UpdateNotifier.shared.notifyUpdateAvailable(info)
                }
            }
        }
        
        // Mark as launched (don't show settings on first boot)
        hasLaunchedBefore = true
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DebugLogger.log("AppDelegate: applicationShouldHandleReopen")
        // Only show settings when explicitly launched from Launchpad/Finder (reopen)
        DispatchQueue.main.async {
            SettingsWindowController.shared.showSettings()
        }
        return true
    }
    
    /// Start the toggle/hanja key monitor, asking for Accessibility first if needed.
    /// Monitor selection, callback wiring and the CGEventTap → IOKit fallback all
    /// live in `ToggleKeyMonitor` (shared with the Settings accessibility flow).
    private func setupToggleKeyMonitoring() {
        if !IOKitManager.hasAccessibilityPermission() {
            DebugLogger.log("Requesting Accessibility permission...")
            IOKitManager.requestAccessibilityPermission()

            // Poll until user grants permission from the system popup
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                DebugLogger.log("Accessibility granted via system popup — starting key monitoring")
                ToggleKeyMonitor.start()
            }
            return
        }

        ToggleKeyMonitor.start()
        DebugLogger.log("Toggle key monitoring initialized")
    }
}

// MARK: - Main Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
