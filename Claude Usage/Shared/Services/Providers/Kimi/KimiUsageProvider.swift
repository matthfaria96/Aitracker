//
//  KimiUsageProvider.swift
//  Aitracker
//
//  Kimi Code (Moonshot) plan limits. Uses the login of the Kimi Code CLI on
//  this Mac (`kimi login` → ~/.kimi-code or ~/.kimi /credentials/kimi-code.json)
//  and the same read-only endpoint the CLI's `/usage` command calls:
//  GET https://api.kimi.com/coding/v1/usages. Reading it costs no quota.
//
//  The response schema is undocumented and has two known shapes, both parsed:
//   A) { "usage": {limit, used|remaining, resetTime},
//        "limits": [{ "window": {duration, timeUnit}, "detail": {...} }] }
//   B) { "usages": { "limit_5h": {used_ratio, reset_time}, "limit_7d": {...} } }
//

import Foundation

// MARK: - Credentials

nonisolated struct KimiCredentials {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var raw: [String: Any]
    let fileURL: URL

    var needsRefresh: Bool { expiresAt.timeIntervalSinceNow < 120 }
}

nonisolated enum KimiAuth {
    static let clientID = "17e5f671-d194-4dfb-9706-5516cb48c098"
    static let tokenURL = URL(string: "https://auth.kimi.com/api/oauth/token")!
    static let usageURL = URL(string: "https://api.kimi.com/coding/v1/usages")!

    /// Candidate home directories, newest layout first.
    static var homeDirectories: [URL] {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        var dirs: [URL] = []
        for key in ["KIMI_CODE_HOME", "KIMI_SHARE_DIR"] {
            if let path = env[key], !path.isEmpty { dirs.append(URL(fileURLWithPath: path)) }
        }
        dirs.append(home.appendingPathComponent(".kimi-code"))
        dirs.append(home.appendingPathComponent(".kimi"))
        return dirs
    }

    static func credentialsFile() -> URL? {
        homeDirectories
            .map { $0.appendingPathComponent("credentials/kimi-code.json") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func isSignedIn() -> Bool { credentialsFile() != nil }

    static func load() throws -> KimiCredentials {
        guard let url = credentialsFile(),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String, !access.isEmpty else {
            throw AppError(
                code: .providerCredentialsNotFound,
                message: NSLocalizedString("accounts.kimi_missing", comment: ""),
                isRecoverable: true
            )
        }
        let expires = (json["expires_at"] as? Double) ?? 0
        return KimiCredentials(
            accessToken: access,
            refreshToken: json["refresh_token"] as? String ?? "",
            expiresAt: Date(timeIntervalSince1970: expires),
            raw: json,
            fileURL: url
        )
    }

    /// Refreshes the access token the same way the CLI does, holding the CLI's
    /// own lock file so the two never rotate the refresh token concurrently,
    /// and writes the new token back so the CLI keeps working.
    static func refresh(_ credentials: KimiCredentials) async throws -> KimiCredentials {
        guard !credentials.refreshToken.isEmpty else { return credentials }

        let lockURL = credentials.fileURL.deletingPathExtension().appendingPathExtension("lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return credentials }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            // The CLI is refreshing right now — use whatever it writes.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            return try load()
        }
        defer { flock(fd, LOCK_UN) }

        // Another process may have refreshed while we waited for the lock.
        let current = try load()
        guard current.needsRefresh else { return current }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("kimi_cli", forHTTPHeaderField: "X-Msh-Platform")
        if let home = homeDirectories.first(where: { current.fileURL.path.hasPrefix($0.path) }),
           let deviceId = try? String(contentsOf: home.appendingPathComponent("device_id"), encoding: .utf8) {
            request.setValue(deviceId.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "X-Msh-Device-Id")
        }
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: current.refreshToken),
        ]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String,
              let refresh = json["refresh_token"] as? String else {
            throw AppError(
                code: .providerAuthExpired,
                message: NSLocalizedString("accounts.kimi_expired", comment: ""),
                technicalDetails: "Kimi token refresh HTTP \(status)",
                isRecoverable: true
            )
        }

        let expiresIn = (json["expires_in"] as? Double) ?? 3600
        var raw = current.raw
        raw["access_token"] = access
        raw["refresh_token"] = refresh
        raw["expires_in"] = expiresIn
        raw["expires_at"] = Date().timeIntervalSince1970 + expiresIn
        if let scope = json["scope"] { raw["scope"] = scope }
        if let type = json["token_type"] { raw["token_type"] = type }

        // Atomic write-back, private permissions — same as the CLI.
        let output = try JSONSerialization.data(withJSONObject: raw)
        let temp = current.fileURL.deletingLastPathComponent().appendingPathComponent(".aitracker-\(UUID().uuidString).tmp")
        try output.write(to: temp)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
        _ = try FileManager.default.replaceItemAt(current.fileURL, withItemAt: temp)

        return KimiCredentials(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(expiresIn),
            raw: raw,
            fileURL: current.fileURL
        )
    }
}

// MARK: - Usage parsing

nonisolated enum KimiUsageParser {
    struct Window {
        var percent: Double
        var resetsAt: Date?
    }

    static func parse(_ json: [String: Any]) -> (session: Window?, weekly: Window?) {
        var session: Window?
        var weekly: Window?

        // Shape B: { usages: { limit_5h: {...}, limit_7d: {...} } }
        if let usages = json["usages"] as? [String: Any] {
            session = window(usages["limit_5h"])
            weekly = window(usages["limit_7d"])
        }

        // Shape A: { usage: {...}, limits: [{ window: {...}, detail: {...} }] }
        if let limits = json["limits"] as? [[String: Any]] {
            for item in limits {
                let detail = (item["detail"] as? [String: Any]) ?? item
                let windowInfo = (item["window"] as? [String: Any]) ?? item
                guard let minutes = windowMinutes(windowInfo), let parsed = window(detail) else { continue }
                if minutes <= 6 * 60 { session = session ?? parsed }
                else if minutes >= 6 * 24 * 60 { weekly = weekly ?? parsed }
            }
        }
        if weekly == nil, let summary = json["usage"] {
            weekly = window(summary)
        }
        return (session, weekly)
    }

    private static func window(_ value: Any?) -> Window? {
        guard let data = value as? [String: Any] else { return nil }

        var percent: Double?
        if let ratio = number(data["used_ratio"] ?? data["usedRatio"]) {
            percent = ratio <= 1 ? ratio * 100 : ratio
        } else if let limit = number(data["limit"]), limit > 0 {
            if let used = number(data["used"]) {
                percent = used / limit * 100
            } else if let remaining = number(data["remaining"]) {
                percent = (limit - remaining) / limit * 100
            }
        }
        guard let percent else { return nil }

        var reset: Date?
        for key in ["reset_time", "resetTime", "reset_at", "resetAt"] {
            if let text = data[key] as? String, let date = parseDate(text) { reset = date; break }
            if let seconds = number(data[key]) { reset = Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds); break }
        }
        if reset == nil, let seconds = number(data["reset_in"] ?? data["resetIn"]) {
            reset = Date().addingTimeInterval(seconds)
        }
        return Window(percent: min(max(percent, 0), 100), resetsAt: reset)
    }

    private static func windowMinutes(_ info: [String: Any]) -> Double? {
        guard let duration = number(info["duration"]) else { return nil }
        let unit = (info["timeUnit"] as? String ?? info["time_unit"] as? String ?? "").uppercased()
        if unit.contains("MINUTE") { return duration }
        if unit.contains("HOUR") { return duration * 60 }
        if unit.contains("DAY") { return duration * 24 * 60 }
        return duration / 60 // seconds
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    static func parseDate(_ text: String) -> Date? {
        // Timestamps may carry nanoseconds ("…05:24:18.443553353Z"); keep millis.
        let trimmed = text.replacingOccurrences(of: #"\.(\d{3})\d+"#, with: ".$1", options: .regularExpression)
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: trimmed) ?? ISO8601DateFormatter().date(from: trimmed)
    }
}

// MARK: - Provider

final class KimiUsageProvider: UsageProviderService {
    static let shared = KimiUsageProvider()
    let provider: Provider = .kimi

    private init() {}

    func hasCredentials(for profile: Profile) -> Bool { KimiAuth.isSignedIn() }

    func fetchUsage(for profile: Profile) async throws -> ClaudeUsage {
        var credentials = try KimiAuth.load()
        if credentials.needsRefresh {
            credentials = try await KimiAuth.refresh(credentials)
        }

        var json = try await requestUsage(token: credentials.accessToken)
        if json == nil, !credentials.refreshToken.isEmpty {
            // 401 before the recorded expiry — refresh once and retry.
            var forced = credentials
            forced.expiresAt = .distantPast
            credentials = try await KimiAuth.refresh(forced)
            json = try await requestUsage(token: credentials.accessToken)
        }
        guard let json else {
            throw AppError(code: .providerAuthExpired, message: NSLocalizedString("accounts.kimi_expired", comment: ""), isRecoverable: true)
        }

        let (session, weekly) = KimiUsageParser.parse(json)
        var usage = ClaudeUsage.empty
        usage.sessionLimit = 0
        usage.weeklyLimit = 0
        usage.sessionPercentage = session?.percent ?? 0
        usage.sessionResetTime = session?.resetsAt ?? Date().addingTimeInterval(5 * 3600)
        if let weekly {
            usage.weeklyPercentage = weekly.percent
            usage.weeklyResetTime = weekly.resetsAt ?? Date().addingTimeInterval(7 * 86400)
        } else {
            // Newer Kimi plans only have the 5-hour window.
            usage.weeklyPercentage = 0
            usage.weeklyResetTime = .distantPast
        }
        usage.lastUpdated = Date()
        usage.userTimezone = .current
        return usage
    }

    /// Returns nil on 401/403 so the caller can refresh and retry.
    private func requestUsage(token: String) async throws -> [String: Any]? {
        var request = URLRequest(url: KimiAuth.usageURL)
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { return nil }
        guard status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError(code: .apiGenericError, message: "Kimi usage request failed", technicalDetails: "HTTP \(status)", isRecoverable: true)
        }
        return json
    }
}
