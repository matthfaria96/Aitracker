//
//  SimpleSettingsView.swift
//  Aitracker
//
//  The whole settings window: accounts + a couple of preferences.
//

import SwiftUI

struct SimpleSettingsView: View {
    @StateObject private var profileManager = ProfileManager.shared
    @State private var showingAddAccount = false
    @State private var isImporting = false
    @State private var message: String?
    @State private var launchAtLogin = LaunchAtLoginManager.shared.isEnabled
    @State private var accountPendingRemoval: Profile?
    @State private var menuBarStyle = MenuBarStyle.current
    @State private var apiKeyProvider: Provider?
    @State private var languageCode = LanguageManager.selectedCode ?? ""
    @State private var languageChanged = false
    @StateObject private var updates = UpdateManager.shared

    /// Opens the add-account sheet right away (first launch).
    var startWithAddAccount = false

    private var accounts: [Profile] {
        profileManager.trackedAccounts
    }

    private var refreshInterval: TimeInterval {
        GeneralSettingsView.closestPreset(to: profileManager.activeProfile?.refreshInterval ?? 120)
    }

    var body: some View {
        Form {
            Section {
                if accounts.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("accounts.empty_title".localized)
                            .font(.system(size: 13, weight: .semibold))
                        Text("accounts.empty_description".localized)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                } else {
                    ForEach(accounts) { account in
                        accountRow(account)
                    }
                }

                HStack {
                    Menu {
                        Button("Claude") { showingAddAccount = true }
                        Button("ChatGPT (Codex)") { addCodexAccount() }
                        Button("Kimi Code") { addKimiAccount() }
                        Button("DeepSeek (API)") { apiKeyProvider = .deepseek }
                        Divider()
                        Button("Meshy (3D)") { apiKeyProvider = .meshy }
                        Button("Tripo (3D)") { apiKeyProvider = .tripo }
                    } label: {
                        Label("accounts.add".localized, systemImage: "plus")
                    }
                    .fixedSize()
                    .disabled(isImporting)

                    if isImporting {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }

                if let message {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("accounts.title".localized)
            }

            Section {
                Picker("menubar_style.title".localized, selection: Binding(
                    get: { menuBarStyle },
                    set: { style in
                        menuBarStyle = style
                        MenuBarStyle.current = style
                        NotificationCenter.default.post(name: .displayModeChanged, object: nil)
                    }
                )) {
                    Text("menubar_style.bars".localized).tag(MenuBarStyle.bars)
                    Text("menubar_style.icon".localized).tag(MenuBarStyle.icon)
                }
                .pickerStyle(.radioGroup)

                if menuBarStyle == .bars {
                    Text("menubar_style.bars_help".localized)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Picker("general.refresh_every".localized, selection: Binding(
                    get: { refreshInterval },
                    set: { applyRefreshInterval($0) }
                )) {
                    ForEach(GeneralSettingsView.refreshPresets, id: \.self) { seconds in
                        Text(GeneralSettingsView.label(for: seconds)).tag(seconds)
                    }
                }

                Picker("settings.language".localized, selection: Binding(
                    get: { languageCode },
                    set: { code in
                        languageCode = code
                        LanguageManager.select(code: code.isEmpty ? nil : code)
                        languageChanged = true
                    }
                )) {
                    Text("settings.language_system".localized).tag("")
                    Divider()
                    ForEach(LanguageManager.SupportedLanguage.allCases) { language in
                        Text(language.displayName).tag(language.code)
                    }
                }

                if languageChanged {
                    HStack {
                        Text("settings.language_restart".localized)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("settings.restart_now".localized, action: relaunch)
                            .controlSize(.small)
                    }
                }

                Toggle("settings.launch_at_login".localized, isOn: Binding(
                    get: { launchAtLogin },
                    set: { enabled in
                        if LaunchAtLoginManager.shared.setEnabled(enabled) {
                            launchAtLogin = enabled
                        }
                    }
                ))

                Toggle("settings.auto_updates".localized, isOn: Binding(
                    get: { updates.automaticChecksEnabled },
                    set: { updates.setAutomaticChecksEnabled($0) }
                ))
            } header: {
                Text("settings.preferences".localized)
            } footer: {
                HStack {
                    Text("Aitracker \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("settings.check_updates".localized) { updates.checkForUpdates() }
                    Button("settings.quit".localized) { NSApp.terminate(nil) }
                }
                .font(.system(size: 11))
                .padding(.top, 8)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 620)
        .sheet(isPresented: $showingAddAccount) {
            BrowserAuthSheet(
                title: "accounts.add".localized,
                loginURL: URL(string: "https://claude.ai/login")!,
                cookieDomain: "claude.ai",
                onSuccess: { result in
                    showingAddAccount = false
                    importAccount(result)
                },
                onCancel: { showingAddAccount = false }
            )
        }
        .sheet(item: $apiKeyProvider) { provider in
            APIKeySheet(provider: provider) { name in
                apiKeyProvider = nil
                if let name { message = String(format: "accounts.added".localized, name) }
            }
        }
        .confirmationDialog(
            String(format: "accounts.remove_confirm".localized, accountPendingRemoval?.name ?? ""),
            isPresented: Binding(get: { accountPendingRemoval != nil }, set: { if !$0 { accountPendingRemoval = nil } })
        ) {
            Button("accounts.remove".localized, role: .destructive) {
                if let account = accountPendingRemoval { remove(account) }
                accountPendingRemoval = nil
            }
        }
        .onAppear {
            renameLegacyAccounts()
            if startWithAddAccount && accounts.isEmpty {
                showingAddAccount = true
            }
        }
    }

    private func accountRow(_ account: Profile) -> some View {
        HStack(spacing: 10) {
            AccountAvatar(name: account.name, color: AccountPalette.color(for: account, in: accounts))
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(account.providerLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if AccountUsage.isBalanceOnly(account) {
                Text(AccountUsage.balance(account.claudeUsage))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(AccountUsage.isOutOfBalance(account.claudeUsage) ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            } else if account.claudeUsage != nil {
                UsageRing(percent: AccountUsage.effective(account.claudeUsage), size: 28, lineWidth: 3.5)
            }
            Menu {
                if account.provider == .anthropic {
                    Button("accounts.reconnect".localized) { showingAddAccount = true }
                    Divider()
                }
                Button("accounts.remove".localized, role: .destructive) { accountPendingRemoval = account }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    // MARK: - Actions

    private func importAccount(_ result: BrowserAuthResult) {
        isImporting = true
        message = nil
        Task {
            do {
                switch try await BrowserAccountImporter.importAccount(sessionKey: result.sessionKey, expiry: result.expiryDate) {
                case .added(let profile):
                    message = String(format: "accounts.added".localized, profile.name)
                case .reconnected(let profile):
                    message = String(format: "accounts.reconnected".localized, profile.name)
                }
            } catch {
                message = AppError.wrap(error).message
            }
            isImporting = false
        }
    }

    /// ChatGPT/Codex: uses the login of the Codex app/CLI on this Mac (~/.codex/auth.json).
    private func addCodexAccount() {
        message = nil
        let auth = CodexAuthService.shared
        guard auth.authFileExists(), let credentials = try? auth.loadFromAuthFile() else {
            message = "accounts.codex_missing".localized
            return
        }
        if profileManager.profiles.contains(where: { $0.provider == .codex }) {
            message = "accounts.codex_exists".localized
            return
        }
        let name = credentials.email ?? "ChatGPT"
        var profile = profileManager.createProfile(name: name, provider: .codex, copySettingsFrom: profileManager.activeProfile)
        profile.isSelectedForDisplay = true
        profileManager.updateProfile(profile)
        message = String(format: "accounts.added".localized, name)
        NotificationCenter.default.post(name: .credentialsChanged, object: nil)
        NotificationCenter.default.post(name: .displayModeChanged, object: nil)
    }

    /// Kimi Code: uses the login of the Kimi Code CLI on this Mac (`kimi login`).
    private func addKimiAccount() {
        message = nil
        guard KimiAuth.isSignedIn() else {
            message = "accounts.kimi_missing".localized
            return
        }
        if profileManager.profiles.contains(where: { $0.provider == .kimi }) {
            message = "accounts.kimi_exists".localized
            return
        }
        var profile = profileManager.createProfile(name: "Kimi", provider: .kimi, copySettingsFrom: profileManager.activeProfile)
        profile.isSelectedForDisplay = true
        profileManager.updateProfile(profile)
        message = String(format: "accounts.added".localized, profile.name)
        NotificationCenter.default.post(name: .credentialsChanged, object: nil)
        NotificationCenter.default.post(name: .displayModeChanged, object: nil)
    }

    private func remove(_ account: Profile) {
        if profileManager.profiles.count > 1 {
            try? profileManager.deleteProfile(account.id)
        } else {
            // Keep one (empty) profile around — the app always needs one.
            try? profileManager.removeClaudeAICredentials(for: account.id)
            if var blank = profileManager.profiles.first(where: { $0.id == account.id }) {
                blank.name = "accounts.default_name".localized
                blank.claudeUsage = nil
                profileManager.updateProfile(blank)
            }
        }
        NotificationCenter.default.post(name: .credentialsChanged, object: nil)
        NotificationCenter.default.post(name: .displayModeChanged, object: nil)
    }

    private func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.7; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }

    private func applyRefreshInterval(_ seconds: TimeInterval) {
        for var profile in profileManager.profiles where profile.refreshInterval != seconds {
            profile.refreshInterval = seconds
            profileManager.updateProfile(profile)
        }
        NotificationCenter.default.post(name: .refreshIntervalChanged, object: nil)
    }

    /// Accounts added before this version carry random names ("Zippy Zebra");
    /// replace them with the account's e-mail.
    private func renameLegacyAccounts() {
        for account in accounts where account.provider == .anthropic && !account.name.contains("@") {
            guard let key = account.claudeSessionKey else { continue }
            Task {
                guard let identity = await ClaudeAPIService().fetchAccountIdentity(sessionKey: key),
                      let name = identity.displayName,
                      var current = profileManager.profiles.first(where: { $0.id == account.id }) else { return }
                current.name = name
                profileManager.updateProfile(current)
            }
        }
    }
}

// MARK: - API key accounts (DeepSeek, Meshy, Tripo)

extension Provider: Identifiable {
    var id: String { rawValue }
}

struct APIKeySheet: View {
    let provider: Provider
    let onDone: (_ addedName: String?) -> Void

    @StateObject private var profileManager = ProfileManager.shared
    @State private var apiKey = ""
    @State private var isChecking = false
    @State private var error: String?

    private var name: String { provider.descriptor.displayName }

    private var keysURL: URL {
        switch provider {
        case .meshy: return URL(string: "https://www.meshy.ai/settings/api")!
        case .tripo: return URL(string: "https://developers.tripo3d.ai")!
        default: return URL(string: "https://platform.deepseek.com/api_keys")!
        }
    }

    private var placeholder: String {
        switch provider {
        case .meshy: return "msy-…"
        case .tripo: return "tsk_…"
        default: return "sk-…"
        }
    }

    private var helpText: String {
        provider == .deepseek ? "accounts.deepseek_help".localized
                              : String(format: "accounts.credits_help".localized, name, name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: provider.descriptor.logoSystemSymbolFallback)
                    .font(.system(size: 18))
                    .foregroundStyle(.tint)
                Text(String(format: "accounts.apikey_title".localized, name))
                    .font(.system(size: 15, weight: .semibold))
            }

            Text(helpText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField(placeholder, text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .onSubmit(save)

            Link(keysURL.host ?? keysURL.absoluteString, destination: keysURL)
                .font(.system(size: 11))

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("common.cancel".localized) { onDone(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(action: save) {
                    if isChecking { ProgressView().controlSize(.small) } else { Text("accounts.add".localized) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty || isChecking)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    /// Validates the key against the provider (also fetching a first balance) before saving.
    private func firstUsage(for key: String) async throws -> ClaudeUsage {
        switch provider {
        case .meshy: return CreditUsage.mapToUsage(try await MeshyUsageProvider.fetchBalance(apiKey: key))
        case .tripo: return CreditUsage.mapToUsage(try await TripoUsageProvider.fetchBalance(apiKey: key))
        default: return DeepSeekUsageProvider.mapToUsage(try await DeepSeekUsageProvider.fetchBalance(apiKey: key))
        }
    }

    private func save() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        isChecking = true
        error = nil
        Task {
            do {
                let usage = try await firstUsage(for: key)
                let existing = profileManager.profiles.filter { $0.provider == provider }.count
                let profileName = existing == 0 ? name : "\(name) \(existing + 1)"
                var profile = profileManager.createProfile(name: profileName, provider: provider, copySettingsFrom: profileManager.activeProfile)
                profile.apiSessionKey = key
                profile.isSelectedForDisplay = true
                profile.claudeUsage = usage
                profileManager.updateProfile(profile)
                NotificationCenter.default.post(name: .credentialsChanged, object: nil)
                NotificationCenter.default.post(name: .displayModeChanged, object: nil)
                isChecking = false
                onDone(profileName)
            } catch {
                self.error = AppError.wrap(error).message
                isChecking = false
            }
        }
    }
}
