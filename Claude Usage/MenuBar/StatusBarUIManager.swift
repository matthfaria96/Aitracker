//
//  StatusBarUIManager.swift
//  Claude Usage
//
//  Created by Claude Code on 2025-12-27.
//

import Cocoa
import Combine

/// Manages multiple menu bar status items for different metrics
final class StatusBarUIManager {
    // Dictionary to hold multiple status items keyed by metric type (single profile mode)
    private var statusItems: [MenuBarMetricType: NSStatusItem] = [:]

    // Dictionary to hold status items keyed by profile ID (multi-profile mode)
    private var multiProfileStatusItems: [UUID: NSStatusItem] = [:]


    // Current display mode
    private var isMultiProfileMode: Bool = false

    private var appearanceObservers: [NSKeyValueObservation] = []
    private var appearanceDebounceTimer: Timer?

    // Image cache to avoid redundant button.image assignments (which trigger KVO)
    private var lastImageData: [ObjectIdentifier: Data] = [:]

    // Icon renderer for creating menu bar images
    private let renderer = MenuBarIconRenderer()

    weak var delegate: StatusBarUIManagerDelegate?

    // MARK: - Stable autosaveName helpers

    /// Base prefix for all status item autosave names.
    /// Ice (icemenubar.app) and macOS use autosaveName to persist item positions.
    private static let autosavePrefix = "claudeUsageTracker"

    /// Returns a stable autosaveName for a single-profile metric item
    private static func autosaveName(for metricType: MenuBarMetricType) -> NSStatusItem.AutosaveName {
        return "\(autosavePrefix).metric.\(metricType.rawValue)"
    }

    /// Returns a stable autosaveName for a multi-profile item by profile ID
    private static func autosaveName(forProfileId id: UUID) -> NSStatusItem.AutosaveName {
        return "\(autosavePrefix).multiProfile.\(id.uuidString)"
    }
    /// Returns a stable autosaveName for the default logo (no credentials)
    private static let defaultLogoAutosaveName: NSStatusItem.AutosaveName = "\(autosavePrefix).defaultLogo"

    /// Fixed placeholder length for freshly-created multi-profile status items. Creating
    /// them at a concrete length (rather than .variableLength) avoids the macOS 26 (Tahoe)
    /// recursive variable-width NSISEngine solve during a multi-item rebuild (profile
    /// switch). updateMultiProfileButtons replaces it with the real coarse-rounded width.
    private static let multiProfilePlaceholderLength: CGFloat = 32

    // MARK: - Multi-profile identity helpers

    /// Well-known placeholder UUID used for the default logo in multi-profile mode
    private static let defaultLogoPlaceholderUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    // MARK: - Initialization

    init() {}

    // MARK: - Setup

    /// Sets up status bar items based on configuration
    func setup(target: AnyObject, action: Selector, config: MenuBarIconConfiguration) {
        // Remove all existing items first
        cleanup()

        // Check if there are any enabled metrics
        if config.enabledMetrics.isEmpty {
            // No credentials/metrics - show default app logo
            let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem.autosaveName = Self.defaultLogoAutosaveName
            // Override any persisted false from a prior cmd-drag.
            statusItem.isVisible = true

            if let button = statusItem.button {
                button.action = action
                button.target = target
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
                // Set a temporary placeholder - will be updated with actual logo
                button.title = ""
            } else {
                LoggingService.shared.logWarning("Status bar button is nil - screens: \(NSScreen.screens.count)")
            }

            // Use a special key to identify the default icon
            statusItems[.session] = statusItem  // Use session as placeholder key
            LoggingService.shared.logUIEvent("Status bar initialized with default app logo (no credentials)")
        } else {
            // Create status items for enabled metrics
            for metricConfig in config.enabledMetrics {
                let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                statusItem.autosaveName = Self.autosaveName(for: metricConfig.metricType)
                // Override any persisted false from a prior cmd-drag.
                statusItem.isVisible = true

                if let button = statusItem.button {
                    button.action = action
                    button.target = target
                    button.sendAction(on: [.leftMouseUp, .rightMouseUp])
                } else {
                    LoggingService.shared.logWarning("Status bar button is nil for \(metricConfig.metricType.displayName) - screens: \(NSScreen.screens.count)")
                }

                statusItems[metricConfig.metricType] = statusItem
            }

            LoggingService.shared.logUIEvent("Status bar initialized with \(config.enabledMetrics.count) metrics")
        }

        observeAppearanceChanges()
    }

    /// Updates status bar items based on new configuration (incremental approach)
    func updateConfiguration(target: AnyObject, action: Selector, config: MenuBarIconConfiguration) {
        // Determine what the new set of items should be
        let newMetricTypes: Set<MenuBarMetricType>
        if config.enabledMetrics.isEmpty {
            // No credentials/metrics - show default app logo using .session as placeholder
            newMetricTypes = [.session]
        } else {
            newMetricTypes = Set(config.enabledMetrics.map { $0.metricType })
        }

        let currentMetricTypes = Set(statusItems.keys)

        // Step 1: Remove items that are no longer needed
        let itemsToRemove = currentMetricTypes.subtracting(newMetricTypes)
        for metricType in itemsToRemove {
            if let statusItem = statusItems[metricType] {
                if let button = statusItem.button {
                    button.image = nil
                    button.action = nil
                    button.target = nil
                }
                NSStatusBar.system.removeStatusItem(statusItem)
                LoggingService.shared.logUIEvent("Removed status item for \(metricType.displayName)")
            }
            statusItems.removeValue(forKey: metricType)
        }

        // Step 2: Add items that are new
        let itemsToAdd = newMetricTypes.subtracting(currentMetricTypes)
        for metricType in itemsToAdd {
            let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            // When enabledMetrics is empty, only .session is in newMetricTypes, so this is safe
            statusItem.autosaveName = config.enabledMetrics.isEmpty
                ? Self.defaultLogoAutosaveName
                : Self.autosaveName(for: metricType)
            // Override any persisted false from a prior cmd-drag.
            statusItem.isVisible = true

            if let button = statusItem.button {
                button.action = action
                button.target = target
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
                if metricType == .session {
                    // Default logo placeholder
                    button.title = ""
                }
            }

            statusItems[metricType] = statusItem
            LoggingService.shared.logUIEvent("Created status item for \(metricType.displayName)")
        }

        // Step 3: Items that already exist don't need recreation, just keep them
        // Their images will be updated by updateAllButtons() or updateButton()

        LoggingService.shared.logUIEvent("Status bar configuration updated: removed=\(itemsToRemove.count), added=\(itemsToAdd.count), kept=\(currentMetricTypes.intersection(newMetricTypes).count)")
    }

    func cleanup() {
        appearanceObservers.forEach { $0.invalidate() }
        appearanceObservers.removeAll()

        // Clean up single profile status items
        for (_, statusItem) in statusItems {
            // Clear button references first
            if let button = statusItem.button {
                button.image = nil
                button.action = nil
                button.target = nil
            }
            // Then remove from status bar
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItems.removeAll()

        // Clean up multi-profile status items
        for (_, statusItem) in multiProfileStatusItems {
            if let button = statusItem.button {
                button.image = nil
                button.action = nil
                button.target = nil
            }
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        multiProfileStatusItems.removeAll()

        isMultiProfileMode = false

        LoggingService.shared.logUIEvent("Status bar cleaned up")
    }

    // MARK: - Multi-Profile Mode

    /// Sets up status bar for multi-profile display mode
    func setupMultiProfile(profiles: [Profile], target: AnyObject, action: Selector) {
        // Aitracker: one menu bar item for all accounts.
        cleanup()
        isMultiProfileMode = true
        ensureAccountsItem(target: target, action: action)
        observeAppearanceChanges()
    }

    /// Incrementally updates multi-profile status items without destroying existing ones.
    /// Only adds/removes items when the set of selected profiles changes.
    func updateMultiProfileConfiguration(profiles: [Profile], target: AnyObject, action: Selector) {
        guard isMultiProfileMode else {
            setupMultiProfile(profiles: profiles, target: target, action: action)
            return
        }
        ensureAccountsItem(target: target, action: action)
    }

    /// Creates the single Aitracker status item if it doesn't exist yet.
    private func ensureAccountsItem(target: AnyObject, action: Selector) {
        // Drop any per-profile items left over from older builds.
        for (id, item) in multiProfileStatusItems where id != Self.defaultLogoPlaceholderUUID {
            NSStatusBar.system.removeStatusItem(item)
            multiProfileStatusItems.removeValue(forKey: id)
        }
        guard multiProfileStatusItems[Self.defaultLogoPlaceholderUUID] == nil else { return }

        let statusItem = NSStatusBar.system.statusItem(withLength: Self.multiProfilePlaceholderLength)
        statusItem.autosaveName = Self.defaultLogoAutosaveName
        statusItem.isVisible = true
        if let button = statusItem.button {
            button.action = action
            button.target = target
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.title = ""
        }
        multiProfileStatusItems[Self.defaultLogoPlaceholderUUID] = statusItem
    }

    /// Adds a thin green underline to an image to indicate the active profile
    private func addGreenUnderline(to image: NSImage) -> NSImage {
        let newImage = NSImage(size: image.size)
        newImage.lockFocus()
        defer { newImage.unlockFocus() }
        // Shift content up 2px to create a 1px gap above the underline
        image.draw(at: NSPoint(x: 0, y: 2), from: .zero, operation: .copy, fraction: 1.0)
        NSColor.systemGreen.setFill()
        NSBezierPath(rect: NSRect(x: 1, y: 0, width: image.size.width - 2, height: 1)).fill()
        return newImage
    }

    /// Updates all multi-profile status items
    func updateMultiProfileButtons(profiles: [Profile], config: MultiProfileDisplayConfig, activeProfileId: UUID? = nil) {
        guard isMultiProfileMode,
              let statusItem = multiProfileStatusItems[Self.defaultLogoPlaceholderUUID],
              let button = statusItem.button else { return }

        let accounts = profiles.filter(\.isTrackedAccount)
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let image = AccountsMenuBarRenderer.image(accounts: accounts, style: MenuBarStyle.current, darkMenuBar: dark)

        // Fixed, explicit width (no variable-length solve — see macOS 26 note).
        let width = ceil(image.size.width) + 10
        if statusItem.length != width { statusItem.length = width }
        button.title = ""
        button.imagePosition = .imageOnly
        button.image = image
        button.toolTip = accounts.map { account in
            ProfileManager.shared.expiredAccountIds.contains(account.id)
                ? "\(account.name): \("accounts.session_expired".localized)"
                : AccountUsage.isBalanceOnly(account)
                ? "\(account.name): \(AccountUsage.balance(account.claudeUsage))"
                : "\(account.name): \(Int(AccountsMenuBarRenderer.effectiveUsage(account.claudeUsage).rounded()))%"
        }.joined(separator: "\n")
    }

    /// Checks if currently in multi-profile mode
    var isInMultiProfileMode: Bool {
        return isMultiProfileMode
    }

    /// Checks if status bar has at least one valid button (for headless mode detection)
    var hasValidStatusBar: Bool {
        // Check single-profile status items
        for (_, statusItem) in statusItems {
            if statusItem.button != nil {
                return true
            }
        }
        // Check multi-profile status items
        for (_, statusItem) in multiProfileStatusItems {
            if statusItem.button != nil {
                return true
            }
        }
        return false
    }

    /// Get button for a specific profile (multi-profile mode)
    func button(for profileId: UUID) -> NSStatusBarButton? {
        return multiProfileStatusItems[profileId]?.button
    }

    /// Find which profile ID owns the given button (multi-profile mode)
    func profileId(for sender: NSStatusBarButton?) -> UUID? {
        guard let sender = sender else { return nil }

        for (profileId, statusItem) in multiProfileStatusItems {
            if statusItem.button === sender {
                return profileId
            }
        }
        return nil
    }

    // MARK: - UI Updates

    /// Updates all status bar buttons based on current usage data
    func updateAllButtons(
        usage: ClaudeUsage,
        apiUsage: APIUsage?
    ) {
        // Get config from active profile
        let profile = ProfileManager.shared.activeProfile
        let config = profile?.iconConfig ?? .default

        // Keep the render path aligned with ClaudeAPIService/MenuBarManager auth
        // fallback logic so users authenticated only via `claude login` don't
        // periodically repaint to the default logo after successful refreshes.
        let hasAnyCredentials = hasAnyAvailableCredentials(for: profile)
        if !hasAnyCredentials || config.enabledMetrics.isEmpty {
            // Show default app logo
            if let statusItem = statusItems[.session],  // We use .session as placeholder key
               let button = statusItem.button {
                // Get actual menu bar appearance from the button
                let menuBarIsDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let logoImage = renderer.createDefaultAppLogo(isDarkMode: menuBarIsDark)
                logoImage.isTemplate = true  // Let macOS handle the color
                setButtonImage(button, image: logoImage)
            }
            return
        }

        // Normal metric display
        for metricConfig in config.enabledMetrics {
            guard let statusItem = statusItems[metricConfig.metricType],
                  let button = statusItem.button else {
                continue
            }

            // Get actual menu bar appearance from the button
            let menuBarIsDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

            // Create image directly using our renderer
            let image = renderer.createImage(
                for: metricConfig.metricType,
                config: metricConfig,
                globalConfig: config,
                usage: usage,
                apiUsage: apiUsage,
                isDarkMode: menuBarIsDark,
                colorMode: config.colorMode,
                singleColorHex: config.singleColorHex,
                showIconName: config.showIconNames,
                showNextSessionTime: metricConfig.showNextSessionTime
            )

            image.isTemplate = config.colorMode == .monochrome && !config.showPaceMarker
            button.image = image
        }
    }

    /// Updates a specific metric's button
    func updateButton(
        for metricType: MenuBarMetricType,
        usage: ClaudeUsage,
        apiUsage: APIUsage?
    ) {
        guard let statusItem = statusItems[metricType],
              let button = statusItem.button else {
            return
        }

        // Get config from active profile
        let config = ProfileManager.shared.activeProfile?.iconConfig ?? .default
        guard let metricConfig = config.config(for: metricType) else {
            return
        }

        // Get the actual menu bar appearance from the button's effective appearance
        let menuBarIsDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        // Create image directly using our renderer
        let image = renderer.createImage(
            for: metricType,
            config: metricConfig,
            globalConfig: config,
            usage: usage,
            apiUsage: apiUsage,
            isDarkMode: menuBarIsDark,
            colorMode: config.colorMode,
            singleColorHex: config.singleColorHex,
            showIconName: config.showIconNames,
            showNextSessionTime: metricConfig.showNextSessionTime
        )

        image.isTemplate = config.colorMode == .monochrome && !config.showPaceMarker
        button.image = image
    }

    /// Mirrors the auth fallback used for actual usage fetches so UI gating does
    /// not disagree with the network layer.
    private func hasAnyAvailableCredentials(for profile: Profile?) -> Bool {
        guard let profile else { return false }

        if profile.hasUsageCredentials { return true }

        do {
            if let systemCreds = try ClaudeCodeSyncService.shared.readSystemCredentials(),
               !ClaudeCodeSyncService.shared.isTokenExpired(systemCreds),
               ClaudeCodeSyncService.shared.extractAccessToken(from: systemCreds) != nil {
                return true
            }
        } catch {
            LoggingService.shared.log("StatusBarUIManager.hasAnyAvailableCredentials: system keychain check failed: \(error.localizedDescription)")
        }

        return false
    }

    /// Get button for a specific metric (used for popover positioning)
    func button(for metricType: MenuBarMetricType) -> NSStatusBarButton? {
        return statusItems[metricType]?.button
    }

    /// Get the first enabled metric's button (for backwards compatibility)
    var primaryButton: NSStatusBarButton? {
        let config = DataStore.shared.loadMenuBarIconConfiguration()
        guard let firstMetric = config.enabledMetrics.first else {
            return nil
        }
        return statusItems[firstMetric.metricType]?.button
    }

    /// Find which metric type owns the given button (sender)
    func metricType(for sender: NSStatusBarButton?) -> MenuBarMetricType? {
        guard let sender = sender else { return nil }

        // Find which status item has this button
        for (metricType, statusItem) in statusItems {
            if statusItem.button === sender {
                return metricType
            }
        }
        return nil
    }

    // MARK: - Appearance Observation

    private var lastObservedAppearanceName: NSAppearance.Name?

    private func observeAppearanceChanges() {
        appearanceObservers.forEach { $0.invalidate() }
        appearanceObservers.removeAll()

        // IMPORTANT: Do NOT observe per-button effectiveAppearance.
        // Setting button.image triggers effectiveAppearance KVO on the button,
        // which causes an infinite redraw loop.
        let appObserver = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, change in
            guard let self = self else { return }
            let newName = change.newValue?.name
            guard newName != self.lastObservedAppearanceName else { return }
            self.lastObservedAppearanceName = newName
            // Clear image cache so next update re-renders with new appearance
            self.lastImageData.removeAll()
            self.delegate?.statusBarAppearanceDidChange()
        }
        appearanceObservers.append(appObserver)
    }

    /// Only sets button.image if the image data actually changed.
    /// This prevents triggering effectiveAppearance KVO when the image is identical.
    private func setButtonImage(_ button: NSStatusBarButton, image: NSImage) {
        let buttonId = ObjectIdentifier(button)
        // Avoid NSImage.tiffRepresentation: macOS 26 SDK crashes in
        // SetupTIFFErrorHandler dispatch_once. Hash via CGImage bytes instead.
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let newData = cg.dataProvider?.data as Data? else {
            button.image = image
            return
        }
        if lastImageData[buttonId] == newData { return }
        lastImageData[buttonId] = newData
        button.image = image
    }

    /// Debounces appearance change notifications so multiple displays/buttons
    /// coalesce into a single delegate callback
    private func scheduleAppearanceUpdate() {
        appearanceDebounceTimer?.invalidate()
        appearanceDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            self?.delegate?.statusBarAppearanceDidChange()
        }
    }
}

// MARK: - Delegate Protocol

protocol StatusBarUIManagerDelegate: AnyObject {
    func statusBarAppearanceDidChange()
}
