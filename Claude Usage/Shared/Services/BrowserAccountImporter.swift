//
//  BrowserAccountImporter.swift
//  Aitracker
//
//  "+ Add account": turns a session key picked up from the browser into a
//  ready-to-use profile — named after the account's e-mail, with its
//  organization selected — so the user never has to manage profiles by hand.
//  Re-importing an account that already exists just reconnects it.
//

import Foundation

@MainActor
enum BrowserAccountImporter {
    enum Outcome {
        case added(Profile)
        case reconnected(Profile)
    }

    static func importAccount(sessionKey: String, expiry: Date?) async throws -> Outcome {
        let api = ClaudeAPIService()
        let organizations = try await api.testSessionKeyWithRetry(sessionKey)
        let identity = await api.fetchAccountIdentity(sessionKey: sessionKey)

        // Prefer the organization that actually has a chat plan.
        let org = organizations.first { $0.capabilities.contains("chat") } ?? organizations[0]
        let name = identity?.displayName ?? org.name

        let manager = ProfileManager.shared
        let outcome: Outcome

        if let existing = manager.profiles.first(where: { $0.provider == .anthropic && $0.name == name }) {
            // Same account again (e.g. its session expired) → refresh credentials.
            outcome = .reconnected(try save(sessionKey: sessionKey, orgId: org.uuid, into: existing))
        } else if let blank = manager.profiles.first(where: { $0.provider == .anthropic && !$0.hasAnyCredentials }) {
            // Fresh install: fill the empty default profile instead of adding a second one.
            var renamed = blank
            renamed.name = name
            outcome = .added(try save(sessionKey: sessionKey, orgId: org.uuid, into: renamed))
        } else {
            let created = manager.createProfile(name: name, provider: .anthropic, copySettingsFrom: manager.activeProfile)
            outcome = .added(try save(sessionKey: sessionKey, orgId: org.uuid, into: created))
        }

        // With two or more accounts, show all of them side by side.
        let connected = manager.profiles.filter { $0.claudeSessionKey != nil && $0.organizationId != nil }
        if connected.count >= 2 && manager.displayMode != .multi {
            manager.updateDisplayMode(.multi)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .displayModeChanged, object: nil)
            }
        }

        ErrorRecovery.shared.recordSuccess(for: .api)
        NotificationCenter.default.post(name: .credentialsChanged, object: nil)
        return outcome
    }

    private static func save(sessionKey: String, orgId: String, into profile: Profile) throws -> Profile {
        var creds = try ProfileStore.shared.loadProfileCredentials(profile.id)
        creds.claudeSessionKey = sessionKey
        creds.organizationId = orgId
        try ProfileStore.shared.saveProfileCredentials(profile.id, credentials: creds)

        var updated = profile
        updated.claudeSessionKey = sessionKey
        updated.organizationId = orgId
        updated.isSelectedForDisplay = true
        ProfileManager.shared.updateProfile(updated)
        ProfileManager.shared.expiredAccountIds.remove(updated.id)
        try? StatuslineService.shared.updateScriptsIfInstalled()
        return updated
    }
}
