//
//  CreditProviders.swift
//  Aitracker
//
//  3D-generation services billed in prepaid credits. Both expose a documented,
//  free, read-only balance endpoint authenticated with an API key (kept in the
//  profile's Keychain-backed `apiSessionKey`):
//   • Meshy  — GET https://api.meshy.ai/openapi/v1/balance
//   • Tripo  — GET https://openapi.tripo3d.ai/v3/account/balance (international)
//              or openapi.tripo3d.com (mainland China; keys are region-bound)
//
//  Balance-only usage is encoded in ClaudeUsage as: creditsBalance = amount,
//  costCurrency = "CREDITS", sessionResetTime = next monthly refill (or
//  .distantPast), overageBalance = credits held by running tasks (Tripo).
//

import Foundation

nonisolated enum CreditBalanceParser {
    struct Balance: Equatable {
        var credits: Double
        var reserved: Double = 0
        var monthlyResetsAt: Date?
    }

    /// { "balance": 1000, "monthly_credits": 600, "permanent_credits": 400, "monthly_resets_at": 1793491200000 }
    static func parseMeshy(_ json: [String: Any]) -> Balance? {
        guard let balance = number(json["balance"]) else { return nil }
        var reset: Date?
        if let millis = number(json["monthly_resets_at"]) {
            reset = Date(timeIntervalSince1970: millis / 1000)
        }
        return Balance(credits: balance, monthlyResetsAt: reset)
    }

    /// { "code": 0, "data": { "balance": 10000.00, "frozen": 200.00 } }
    static func parseTripo(_ json: [String: Any]) -> Balance? {
        if let code = number(json["code"]), code != 0 { return nil }
        let data = (json["data"] as? [String: Any]) ?? json
        guard let balance = number(data["balance"]) else { return nil }
        return Balance(credits: balance, reserved: number(data["frozen"]) ?? 0)
    }

    static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }
}

enum CreditUsage {
    static let creditsCurrency = "CREDITS"

    static func mapToUsage(_ balance: CreditBalanceParser.Balance) -> ClaudeUsage {
        var usage = ClaudeUsage.empty
        usage.sessionLimit = 0
        usage.weeklyLimit = 0
        usage.sessionPercentage = 0
        usage.weeklyPercentage = 0
        usage.sessionResetTime = balance.monthlyResetsAt ?? .distantPast
        usage.weeklyResetTime = .distantPast
        usage.creditsBalance = balance.credits
        usage.creditsUnlimited = false
        usage.costCurrency = creditsCurrency
        usage.overageBalance = balance.reserved > 0 ? balance.reserved : nil
        usage.planType = balance.credits > 0 ? "available" : "insufficient"
        usage.lastUpdated = Date()
        usage.userTimezone = .current
        return usage
    }

    /// GET `url` with a Bearer API key and parse the JSON body.
    static func fetchJSON(url: URL, apiKey: String) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw AppError(code: .providerAuthExpired, message: NSLocalizedString("accounts.apikey_invalid", comment: ""), isRecoverable: true)
        }
        guard status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError(code: .apiGenericError, message: "Balance request failed", technicalDetails: "\(url.host ?? "") HTTP \(status)", isRecoverable: true)
        }
        return json
    }
}

final class MeshyUsageProvider: UsageProviderService {
    static let shared = MeshyUsageProvider()
    let provider: Provider = .meshy
    static let balanceURL = URL(string: "https://api.meshy.ai/openapi/v1/balance")!
    private init() {}

    func hasCredentials(for profile: Profile) -> Bool { profile.apiSessionKey != nil }

    func fetchUsage(for profile: Profile) async throws -> ClaudeUsage {
        CreditUsage.mapToUsage(try await Self.fetchBalance(apiKey: profile.apiSessionKey ?? ""))
    }

    static func fetchBalance(apiKey: String) async throws -> CreditBalanceParser.Balance {
        let json = try await CreditUsage.fetchJSON(url: balanceURL, apiKey: apiKey)
        guard let balance = CreditBalanceParser.parseMeshy(json) else {
            throw AppError(code: .apiParsingFailed, message: "Unexpected Meshy balance response", isRecoverable: true)
        }
        return balance
    }
}

final class TripoUsageProvider: UsageProviderService {
    static let shared = TripoUsageProvider()
    let provider: Provider = .tripo
    /// Keys only work in the region they were issued for — try international first.
    static let balanceURLs = [
        URL(string: "https://openapi.tripo3d.ai/v3/account/balance")!,
        URL(string: "https://openapi.tripo3d.com/v3/account/balance")!,
    ]
    private init() {}

    func hasCredentials(for profile: Profile) -> Bool { profile.apiSessionKey != nil }

    func fetchUsage(for profile: Profile) async throws -> ClaudeUsage {
        CreditUsage.mapToUsage(try await Self.fetchBalance(apiKey: profile.apiSessionKey ?? ""))
    }

    static func fetchBalance(apiKey: String) async throws -> CreditBalanceParser.Balance {
        var lastError: Error?
        for url in balanceURLs {
            do {
                let json = try await CreditUsage.fetchJSON(url: url, apiKey: apiKey)
                if let balance = CreditBalanceParser.parseTripo(json) { return balance }
            } catch {
                lastError = error
                // Only an auth rejection means "maybe the other region".
                guard AppError.wrap(error).code == .providerAuthExpired else { throw error }
            }
        }
        if let lastError { throw lastError }
        throw AppError(code: .apiParsingFailed, message: "Unexpected Tripo balance response", isRecoverable: true)
    }
}
