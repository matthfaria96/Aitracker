//
//  BrowserAuthSheet.swift
//  Aitracker
//
//  Sign-in through the user's own browser. Opens the login page in the
//  default browser (or a chosen one / chosen profile), then watches that
//  browser's cookie store until a session for the target domain shows up.
//  Sessions that already exist in any profile are listed so the user can just
//  pick one — which is also how several accounts from the same company get
//  added: one browser profile per account.
//

import Combine
import SwiftUI

// MARK: - Result

struct BrowserAuthResult {
    let sessionKey: String
    let expiryDate: Date?
}

// MARK: - Model

@MainActor
final class BrowserAuthModel: ObservableObject {
    struct FoundSession: Identifiable {
        let cookie: BrowserSessionCookie
        var identity: ClaudeAPIService.AccountIdentity?
        var organizations: [String] = []
        var isResolving = true
        var isInvalid = false
        /// Aitracker profile that already uses this exact session key.
        var usedByProfile: String?

        var id: String { cookie.id }
    }

    let loginURL: URL
    let cookieDomain: String

    @Published var browsers: [SupportedBrowser] = []
    @Published var selectedBrowserId: String = "" {
        didSet {
            guard oldValue != selectedBrowserId else { return }
            reloadProfiles()
            keychainError = nil
            sessions = []
            baseline = nil
            scanNow()
        }
    }
    @Published var profiles: [BrowserProfile] = []
    @Published var selectedProfileId: String = ""
    @Published var sessions: [FoundSession] = []
    @Published var isWaitingForLogin = false
    @Published var keychainError: String?
    @Published var hasScanned = false
    @Published var didStart = false

    private let service = BrowserCookieService.shared
    private let apiService = ClaudeAPIService()
    private var pollTask: Task<Void, Never>?
    /// Session values present when the user pressed "open login"; a value
    /// that shows up afterwards is the login that just happened.
    private var baseline: Set<String>?
    private var onAutoSelect: ((FoundSession) -> Void)?

    init(loginURL: URL, cookieDomain: String) {
        self.loginURL = loginURL
        self.cookieDomain = cookieDomain
    }

    var defaultBrowserId: String? { service.defaultBrowserBundleIdentifier() }

    var selectedBrowser: SupportedBrowser? {
        browsers.first { $0.id == selectedBrowserId }
    }

    var selectedProfile: BrowserProfile? {
        profiles.first { $0.id == selectedProfileId }
    }

    var resolvesIdentity: Bool { cookieDomain == "claude.ai" }

    func start(onAutoSelect: @escaping (FoundSession) -> Void) {
        self.onAutoSelect = onAutoSelect
        browsers = service.installedBrowsers()
        didStart = true
        // installedBrowsers() puts the system default first.
        if let first = browsers.first {
            selectedBrowserId = first.id
        }
        startPolling()
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func reloadProfiles() {
        guard let browser = selectedBrowser else { profiles = []; return }
        profiles = service.profiles(for: browser)
        if !profiles.contains(where: { $0.id == selectedProfileId }) {
            selectedProfileId = profiles.first?.id ?? ""
        }
    }

    func openLogin() {
        baseline = Set(sessions.map(\.cookie.value))
        isWaitingForLogin = true
        service.open(loginURL, in: selectedBrowser, profile: selectedProfile)
    }

    func retry() {
        keychainError = nil
        scanNow()
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                // Chromium only flushes cookies to disk every few seconds, so a
                // 2s poll is plenty; skip while the Keychain refused access so
                // we don't re-prompt the user in a loop.
                if let self, self.keychainError == nil {
                    await self.scan()
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func scanNow() {
        Task { await scan() }
    }

    private var isScanning = false

    private func scan() async {
        guard !isScanning, let browser = selectedBrowser else { return }
        isScanning = true
        defer { isScanning = false }

        let domain = cookieDomain
        let service = self.service
        let result = await Task.detached(priority: .userInitiated) {
            service.findCookies(named: "sessionKey", domain: domain, in: [browser])
        }.value

        // The user may have switched browsers while we were reading.
        guard browser.id == selectedBrowserId else { return }
        hasScanned = true

        if let error = result.errors[browser.id] {
            keychainError = error.localizedDescription
        }

        merge(result.cookies)
    }

    private func merge(_ cookies: [BrowserSessionCookie]) {
        // One entry per distinct session value (a value can't be in two
        // profiles, but be defensive and keep the first, most recent one).
        var seen = Set<String>()
        let unique = cookies.filter { seen.insert($0.value).inserted }

        let existing = Dictionary(uniqueKeysWithValues: sessions.map { ($0.cookie.value, $0) })
        let usedBy = profileUsage()

        sessions = unique.map { cookie in
            if var known = existing[cookie.value] {
                known.usedByProfile = usedBy[cookie.value]
                return known
            }
            var fresh = FoundSession(cookie: cookie)
            fresh.usedByProfile = usedBy[cookie.value]
            fresh.isResolving = resolvesIdentity
            return fresh
        }

        for session in sessions where session.isResolving && existing[session.cookie.value] == nil {
            resolve(session.cookie.value)
        }

        // A new session appeared after the user opened the login page → done.
        if isWaitingForLogin, let baseline,
           let newSession = sessions.first(where: { !baseline.contains($0.cookie.value) }) {
            isWaitingForLogin = false
            self.baseline = nil
            onAutoSelect?(newSession)
        }
    }

    private func profileUsage() -> [String: String] {
        var map: [String: String] = [:]
        for profile in ProfileManager.shared.profiles {
            let key = resolvesIdentity ? profile.claudeSessionKey : profile.apiSessionKey
            if let key, !key.isEmpty { map[key] = profile.name }
        }
        return map
    }

    private func resolve(_ value: String) {
        Task {
            async let identity = apiService.fetchAccountIdentity(sessionKey: value)
            let organizations = try? await apiService.testSessionKey(value)
            let resolvedIdentity = await identity

            guard let index = sessions.firstIndex(where: { $0.cookie.value == value }) else { return }
            sessions[index].identity = resolvedIdentity
            sessions[index].organizations = organizations?.map(\.name) ?? []
            sessions[index].isInvalid = organizations == nil && resolvedIdentity == nil
            sessions[index].isResolving = false
        }
    }
}

// MARK: - Sheet

struct BrowserAuthSheet: View {
    let title: String
    let loginURL: URL
    let cookieDomain: String
    let onSuccess: (BrowserAuthResult) -> Void
    let onCancel: () -> Void

    @StateObject private var model: BrowserAuthModel

    init(
        title: String,
        loginURL: URL,
        cookieDomain: String,
        onSuccess: @escaping (BrowserAuthResult) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.title = title
        self.loginURL = loginURL
        self.cookieDomain = cookieDomain
        self.onSuccess = onSuccess
        self.onCancel = onCancel
        _model = StateObject(wrappedValue: BrowserAuthModel(loginURL: loginURL, cookieDomain: cookieDomain))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if model.didStart && model.browsers.isEmpty {
                noBrowserView
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        browserPicker
                        openLoginSection
                        if let error = model.keychainError {
                            keychainErrorBanner(error)
                        }
                        sessionsSection
                        multiAccountHint
                    }
                    .padding(20)
                }
            }
        }
        .frame(width: 540, height: 600)
        .onAppear {
            model.start { session in
                select(session)
            }
        }
        .onDisappear { model.stop() }
    }

    // MARK: Sections

    private var header: some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button("common.cancel".localized) {
                model.stop()
                onCancel()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var noBrowserView: some View {
        VStack(spacing: 12) {
            Image(systemName: "globe.badge.chevron.backward")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text("browser_auth.no_browser".localized)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var browserPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("browser_auth.browser".localized)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 80, alignment: .leading)
                Picker("", selection: $model.selectedBrowserId) {
                    ForEach(model.browsers) { browser in
                        Text(browser.id == model.defaultBrowserId
                             ? String(format: "browser_auth.default_suffix".localized, browser.name)
                             : browser.name)
                            .tag(browser.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
            }

            if model.profiles.count > 1, model.selectedBrowser?.engine == .chromium {
                HStack(spacing: 12) {
                    Text("browser_auth.profile".localized)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 80, alignment: .leading)
                    Picker("", selection: $model.selectedProfileId) {
                        ForEach(model.profiles) { profile in
                            Text(profile.displayName).tag(profile.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260)
                }
            }
        }
    }

    private var openLoginSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: model.openLogin) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.forward.app")
                    Text(String(format: "browser_auth.open_login".localized, model.selectedBrowser?.name ?? "browser"))
                }
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.selectedBrowser == nil)

            if model.isWaitingForLogin {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(String(format: "browser_auth.waiting".localized, model.selectedBrowser?.name ?? ""))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("browser_auth.open_login_hint".localized)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func keychainErrorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.trianglebadge.exclamationmark")
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                Button("browser_auth.retry".localized, action: model.retry)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
        .cornerRadius(6)
    }

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("browser_auth.found_sessions".localized)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)

            if model.sessions.isEmpty {
                Text(model.hasScanned ? "browser_auth.no_sessions".localized : "browser_auth.scanning".localized)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(model.sessions) { session in
                    sessionRow(session)
                }
            }
        }
    }

    private func sessionRow(_ session: BrowserAuthModel.FoundSession) -> some View {
        HStack(spacing: 10) {
            Image(systemName: session.isInvalid ? "person.crop.circle.badge.xmark" : "person.crop.circle")
                .font(.system(size: 22))
                .foregroundColor(session.isInvalid ? .secondary : .accentColor)

            VStack(alignment: .leading, spacing: 2) {
                if session.isResolving {
                    Text("browser_auth.identifying".localized)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                } else {
                    Text(session.identity?.displayName
                         ?? session.organizations.first
                         ?? "browser_auth.unknown_account".localized)
                        .font(.system(size: 12, weight: .medium))
                }

                Text(subtitle(for: session))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)

                if let profileName = session.usedByProfile {
                    Text(String(format: "browser_auth.used_by".localized, profileName))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.orange)
                } else if session.isInvalid {
                    Text("browser_auth.expired".localized)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.red)
                }
            }

            Spacer()

            Button("browser_auth.use".localized) { select(session) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(session.isInvalid)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.gray.opacity(0.2), lineWidth: 1)
        )
    }

    private func subtitle(for session: BrowserAuthModel.FoundSession) -> String {
        var parts = ["\(session.cookie.profile.browser.name) · \(session.cookie.profile.displayName)"]
        if session.identity != nil, !session.organizations.isEmpty {
            parts.append(session.organizations.joined(separator: ", "))
        }
        return parts.joined(separator: " — ")
    }

    private var multiAccountHint: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "person.2")
                .foregroundColor(.secondary)
            Text("browser_auth.multi_account_hint".localized)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(6)
    }

    // MARK: Actions

    private func select(_ session: BrowserAuthModel.FoundSession) {
        model.stop()
        onSuccess(BrowserAuthResult(
            sessionKey: session.cookie.value,
            expiryDate: session.cookie.expiresAt
        ))
    }
}
