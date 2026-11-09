import Cocoa
import SwiftUI
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var menuBarManager: MenuBarManager?
    private var setupWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Disable window restoration for menu bar app
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")

        // Set app icon early for Stage Manager and windows
        if let appIcon = NSImage(named: "AppIcon") {
            NSApp.applicationIconImage = appIcon
        }

        // Hide dock icon (menu bar app only)
        NSApp.setActivationPolicy(.accessory)

        // Load profiles into ProfileManager (synchronously)
        ProfileManager.shared.loadProfiles()

        // In-app updates (daily check, witchmymac.com feed)
        _ = UpdateManager.shared

        // Request notification permissions
        requestNotificationPermissions()

        // Create the menu bar up front (see #197: the window may fail to show on Tahoe).
        menuBarManager = MenuBarManager()
        menuBarManager?.setup()

        // No account yet → open the window straight into "Add account".
        let hasAccount = ProfileManager.shared.profiles.contains { $0.claudeSessionKey != nil }
        if !hasAccount {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.menuBarManager?.openSettings(startWithAddAccount: true)
            }
        }

        // Headless support: delayed retry for Remote Desktop scenarios
        // If status bar failed to initialize (headless Mac), retry after a delay when displays connect
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self = self else { return }

            // Only retry if we have screens now but status bar failed
            if !NSScreen.screens.isEmpty && self.menuBarManager?.hasValidStatusBar() == false {
                LoggingService.shared.log("AppDelegate: Delayed retry of status bar setup (headless support)")
                self.menuBarManager?.setup()
            }
        }
    }

    private func requestNotificationPermissions() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
            // Silently request permissions
        }
    }


    private func shouldShowSetupWizard() -> Bool {
        // FORCE SHOW wizard on very first app launch (one-time)
        // This ensures users see the migration option if they have old data
        if !SharedDataStore.shared.hasShownWizardOnce() {
            LoggingService.shared.log("AppDelegate: First launch - forcing wizard to show migration option")
            return true
        }

        // After first launch, use normal checks:

        // activeProfile will always exist after loadProfiles() is called
        // (ProfileManager creates a default profile if none exist)
        guard let activeProfile = ProfileManager.shared.activeProfile else {
            return true  // Safety fallback, should never happen
        }

        // If profile already has any credentials, skip wizard
        if activeProfile.hasAnyCredentials {
            return false
        }

        // Check if valid CLI credentials exist in system Keychain
        // (Claude Code specific — only relevant for providers with CLI sync)
        if activeProfile.provider.descriptor.capabilities.cliAccountSync,
           hasValidSystemCLICredentials() {
            LoggingService.shared.log("AppDelegate: Found valid CLI credentials, skipping wizard")
            return false
        }

        // No credentials found - show wizard
        return true
    }

    /// Checks if valid Claude Code CLI credentials exist in system Keychain
    private func hasValidSystemCLICredentials() -> Bool {
        do {
            // Attempt to read credentials from system Keychain
            guard let jsonData = try ClaudeCodeSyncService.shared.readSystemCredentials() else {
                LoggingService.shared.log("AppDelegate: No CLI credentials found in system Keychain")
                return false
            }

            // Validate: not expired
            if ClaudeCodeSyncService.shared.isTokenExpired(jsonData) {
                LoggingService.shared.log("AppDelegate: CLI credentials found but expired")
                return false
            }

            // Validate: has valid access token
            guard ClaudeCodeSyncService.shared.extractAccessToken(from: jsonData) != nil else {
                LoggingService.shared.log("AppDelegate: CLI credentials found but missing access token")
                return false
            }

            LoggingService.shared.log("AppDelegate: Valid CLI credentials found in system Keychain")
            return true

        } catch {
            LoggingService.shared.logError("AppDelegate: Failed to check CLI credentials", error: error)
            return false
        }
    }

    /// Handles notification to show setup wizard
    @objc private func handleShowSetupWizard() {
        LoggingService.shared.log("AppDelegate: Received showSetupWizard notification")
        showSetupWizardManually()
    }

    /// Shows the setup wizard window (can be called manually for testing)
    func showSetupWizardManually() {
        LoggingService.shared.log("AppDelegate: showSetupWizardManually called")

        // Temporarily show dock icon for the setup window
        NSApp.setActivationPolicy(.regular)
        LoggingService.shared.log("AppDelegate: Set activation policy to regular")

        let setupView = SetupWizardView()
        let hostingController = NSHostingController(rootView: setupView)
        LoggingService.shared.log("AppDelegate: Created hosting controller")

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Aitracker Setup"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        LoggingService.shared.log("AppDelegate: Window created and made key")

        // Hide dock icon again when setup window closes
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            NSApp.setActivationPolicy(.accessory)
            self?.setupWindow = nil

            // Initialize status bar after setup completes. `menuBarManager` is
            // now always created in `applicationDidFinishLaunching`, so we only
            // need to call `setup()` if the status bar hasn't been configured yet.
            if self?.menuBarManager?.hasValidStatusBar() != true {
                self?.menuBarManager?.setup()
            }
        }

        setupWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuBarManager?.cleanup()
    }

    // MARK: - Claude Code Notch HUD

    @objc private func handleNotchHUDSettingChanged() {
        updateNotchHUDServices()
    }

    private func updateNotchHUDServices() {
        if SharedDataStore.shared.loadNotchHUDEnabled() {
            NotchHUDController.shared.start()
            NotchHookServer.shared.start()
            // Self-heal hook config drift (e.g. legacy entries from an old build).
            if NotchHookInstaller.shared.checkStatus() != .installed {
                NotchHookInstaller.shared.install()
            }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--mock-notch") {
                NotchHUDController.shared.injectMockSessions()
            }
            #endif
        } else {
            NotchHookServer.shared.stop()
            NotchHUDController.shared.stop()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running even if all windows are closed
        return false
    }

    func application(_ application: NSApplication, willEncodeRestorableState coder: NSCoder) {
        // Prevent window restoration state from being saved
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        // Disable state restoration for menu bar app
        return false
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show notifications even when app is in foreground (menu bar apps are always foreground)
        completionHandler([.banner, .sound])
    }
}
