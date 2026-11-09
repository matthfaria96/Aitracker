//
//  DeepSeekUsageProvider.swift
//  Aitracker
//
//  DeepSeek is pay-as-you-go: there are no 5-hour/weekly windows, just a
//  prepaid API balance. Reads it with the documented, read-only endpoint
//  GET https://api.deepseek.com/user/balance (costs nothing). The API key is
//  kept in the profile's `apiSessionKey` slot, which lives in the Keychain.
//

import Foundation

nonisolated enum DeepSeekBalanceParser {
    struct Balance: Equatable {
        let isAvailable: Bool
        let currency: String
        let total: Double
        let granted: Double
        let toppedUp: Double
    }

    /// Picks USD when present, otherwise the first currency reported.
    static func parse(_ json: [String: Any]) -> Balance? {
        guard let infos = json["balance_infos"] as? [[String: Any]], !infos.isEmpty else { return nil }
        let info = infos.first { ($0["currency"] as? String)?.uppercased() == "USD" } ?? infos[0]
        func number(_ key: String) -> Double {
            if let s = info[key] as? String { return Double(s) ?? 0 }
            return (info[key] as? NSNumber)?.doubleValue ?? 0
        }
        return Balance(
            isAvailable: json["is_available"] as? Bool ?? (number("total_balance") > 0),
            currency: (info["currency"] as? String ?? "USD").uppercased(),
            total: number("total_balance"),
            granted: number("granted_balance"),
            toppedUp: number("topped_up_balance")
        )
    }
}

final class DeepSeekUsageProvider: UsageProviderService {
    static let shared = DeepSeekUsageProvider()
    let provider: Provider = .deepseek

    static let balanceURL = URL(string: "https://api.deepseek.com/user/balance")!

    private init() {}

    func hasCredentials(for profile: Profile) -> Bool { profile.apiSessionKey != nil }

    func fetchUsage(for profile: Profile) async throws -> ClaudeUsage {
        guard let key = profile.apiSessionKey, !key.isEmpty else {
            throw AppError(code: .providerCredentialsNotFound, message: "accounts.deepseek_invalid".localized, isRecoverable: true)
        }
        let balance = try await Self.fetchBalance(apiKey: key)
        return Self.mapToUsage(balance)
    }

    static func fetchBalance(apiKey: String) async throws -> DeepSeekBalanceParser.Balance {
        var request = URLRequest(url: balanceURL)
        request.timeoutInterval = 20
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw AppError(code: .providerAuthExpired, message: NSLocalizedString("accounts.deepseek_invalid", comment: ""), isRecoverable: true)
        }
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let balance = DeepSeekBalanceParser.parse(json) else {
            throw AppError(code: .apiGenericError, message: "DeepSeek balance request failed", technicalDetails: "HTTP \(status)", isRecoverable: true)
        }
        return balance
    }

    /// Balance-only account: no usage windows (marked with .distantPast).
    static func mapToUsage(_ balance: DeepSeekBalanceParser.Balance) -> ClaudeUsage {
        var usage = ClaudeUsage.empty
        usage.sessionLimit = 0
        usage.weeklyLimit = 0
        usage.sessionPercentage = 0
        usage.weeklyPercentage = 0
        usage.sessionResetTime = .distantPast
        usage.weeklyResetTime = .distantPast
        usage.creditsBalance = balance.total
        usage.creditsUnlimited = false
        usage.costCurrency = balance.currency
        usage.planType = balance.isAvailable ? "available" : "insufficient"
        usage.lastUpdated = Date()
        usage.userTimezone = .current
        return usage
    }
}
