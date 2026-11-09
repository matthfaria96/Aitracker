//
//  ClaudeAPIService+Identity.swift
//  Aitracker
//
//  Resolves which claude.ai *account* a session key belongs to. Organization
//  data alone can't tell two seats of the same company apart, so the browser
//  sign-in uses this to label each session it finds with the user's e-mail.
//

import Foundation

extension ClaudeAPIService {
    struct AccountIdentity: Equatable {
        let accountUuid: String?
        let email: String?
        let fullName: String?

        var displayName: String? { email ?? fullName }
    }

    /// Best-effort lookup of the account behind `sessionKey`. Tries the account
    /// endpoint, then the web app's bootstrap payload; returns nil when neither
    /// yields an identity (the caller then falls back to organization names).
    func fetchAccountIdentity(sessionKey: String) async -> AccountIdentity? {
        for path in ["/account", "/bootstrap"] {
            guard let url = URL(string: baseURL + path) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 20
            request.httpShouldHandleCookies = false
            request.setValue(Self.sessionCookieHeader(sessionKey: sessionKey, url: url), forHTTPHeaderField: "Cookie")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
            request.setValue("https://claude.ai", forHTTPHeaderField: "Referer")
            request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")

            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let account = (root["account"] as? [String: Any]) ?? root
            let email = (account["email_address"] as? String) ?? (account["email"] as? String)
            let name = (account["full_name"] as? String) ?? (account["display_name"] as? String) ?? (account["name"] as? String)
            let uuid = account["uuid"] as? String
            if email != nil || name != nil {
                return AccountIdentity(accountUuid: uuid, email: email, fullName: name)
            }
        }
        return nil
    }
}
