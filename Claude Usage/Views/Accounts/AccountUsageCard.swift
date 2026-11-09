//
//  AccountUsageCard.swift
//  Aitracker
//
//  Building blocks for showing an account's usage: a stable color per
//  account, a ring with the "how used up is it" number, and an expandable
//  row with the 5-hour / weekly / extra-usage details.
//

import SwiftUI

// MARK: - Which profiles are "accounts"

extension Profile {
    /// A profile Aitracker shows: a connected Claude account or a Codex (ChatGPT) login.
    var isTrackedAccount: Bool {
        switch provider {
        case .anthropic: return claudeSessionKey != nil
        case .codex, .kimi: return hasAnyCredentials
        case .deepseek, .meshy, .tripo: return apiSessionKey != nil
        }
    }

    var providerLabel: String {
        switch provider {
        case .anthropic: return "Claude"
        case .codex: return "Codex"
        case .kimi: return "Kimi Code"
        case .deepseek: return "DeepSeek API"
        case .meshy: return "Meshy · 3D"
        case .tripo: return "Tripo · 3D"
        }
    }
}

extension ProfileManager {
    var trackedAccounts: [Profile] { profiles.filter(\.isTrackedAccount) }
}

// MARK: - Color per account

enum AccountPalette {
    static let colors: [NSColor] = [.systemBlue, .systemPurple, .systemPink, .systemOrange, .systemTeal, .systemIndigo, .systemMint, .systemBrown]

    /// Colors follow the account order, so neighbours never share a color.
    static func nsColor(for profile: Profile, in accounts: [Profile]) -> NSColor {
        let index = accounts.firstIndex(where: { $0.id == profile.id }) ?? 0
        return colors[index % colors.count]
    }

    static func color(for profile: Profile, in accounts: [Profile]) -> Color {
        Color(nsColor: nsColor(for: profile, in: accounts))
    }
}

// MARK: - Usage logic shared with the menu bar

enum AccountUsage {
    /// Weekly usage, except a maxed-out 5-hour limit means "blocked now" → 100%.
    static func effective(_ usage: ClaudeUsage?) -> Double {
        guard let usage else { return 0 }
        if !hasWeeklyLimit(usage) { return min(max(usage.effectiveSessionPercentage, 0), 100) }
        let weekly = min(max(usage.weeklyPercentage, 0), 100)
        return usage.effectiveSessionPercentage >= 100 ? 100 : weekly
    }

    /// Pay-as-you-go accounts (DeepSeek) have a prepaid balance, no windows.
    static func isBalanceOnly(_ profile: Profile) -> Bool {
        [.deepseek, .meshy, .tripo].contains(profile.provider)
    }

    static func isCredits(_ usage: ClaudeUsage?) -> Bool {
        usage?.costCurrency == CreditUsage.creditsCurrency
    }

    static func isOutOfBalance(_ usage: ClaudeUsage?) -> Bool {
        guard let usage else { return false }
        return usage.planType == "insufficient" || (usage.creditsBalance ?? 0) <= 0
    }

    static func balance(_ usage: ClaudeUsage?) -> String {
        guard let usage, let amount = usage.creditsBalance else { return "–" }
        if isCredits(usage) {
            return String(format: "accounts.credits_amount".localized, amount.formatted(.number.precision(.fractionLength(0...2))))
        }
        return amount.formatted(.currency(code: usage.costCurrency ?? "USD"))
    }

    /// Compact amount for the menu bar ("$12", "¥110").
    static func shortBalance(_ usage: ClaudeUsage?) -> String {
        guard let usage, let amount = usage.creditsBalance else { return "–" }
        if isCredits(usage) {
            return amount.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
        }
        return amount.formatted(.currency(code: usage.costCurrency ?? "USD").precision(.fractionLength(amount < 10 ? 2 : 0)))
    }

    /// Some plans (newer Kimi Code) only have the 5-hour window.
    static func hasWeeklyLimit(_ usage: ClaudeUsage) -> Bool {
        usage.weeklyResetTime != .distantPast
    }

    static func isBlockedBySession(_ usage: ClaudeUsage?) -> Bool {
        (usage?.effectiveSessionPercentage ?? 0) >= 100
    }

    /// The reset that matters for the effective number.
    static func relevantReset(_ usage: ClaudeUsage?) -> Date? {
        guard let usage else { return nil }
        let date = (isBlockedBySession(usage) || !hasWeeklyLimit(usage)) ? usage.sessionResetTime : usage.weeklyResetTime
        return date > Date() ? date : nil
    }

    static func tint(_ percent: Double) -> Color {
        switch percent {
        case ..<70: return .green
        case ..<90: return .orange
        default: return .red
        }
    }
}

// MARK: - Avatar

struct AccountAvatar: View {
    let name: String
    var color: Color = .accentColor
    var size: CGFloat = 26

    var body: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(color.gradient))
    }
}

// MARK: - Ring

struct UsageRing: View {
    let percent: Double
    var size: CGFloat = 34
    var lineWidth: CGFloat = 4

    private var value: Double { min(max(percent, 0), 100) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.1), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: value / 100)
                .stroke(AccountUsage.tint(value), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(value.rounded()))")
                .font(.system(size: size * 0.32, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .frame(width: size, height: size)
        .animation(.smooth(duration: 0.5), value: value)
    }
}

// MARK: - Row (popover)

struct AccountRow: View {
    let profile: Profile
    let color: Color
    @Binding var isExpanded: Bool
    var isExpired = false

    @State private var isHovered = false

    private var usage: ClaudeUsage? { profile.claudeUsage }
    private var effective: Double { AccountUsage.effective(usage) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    AccountAvatar(name: profile.name, color: color)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.name)
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(subtitleIsWarning ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    if isExpired {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.orange)
                            .frame(width: 34)
                    } else if AccountUsage.isBalanceOnly(profile), usage != nil {
                        Text(AccountUsage.balance(usage))
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(AccountUsage.isOutOfBalance(usage) ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                            .contentTransition(.numericText())
                    } else if usage != nil {
                        UsageRing(percent: effective)
                    } else {
                        ProgressView().controlSize(.small).frame(width: 34)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded, !isExpired, let usage, !AccountUsage.isBalanceOnly(profile) {
                AccountDetails(usage: usage)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(isExpanded ? 0.06 : (isHovered ? 0.05 : 0)))
        )
        .onHover { isHovered = $0 }
    }

    private var subtitleIsWarning: Bool {
        isExpired || AccountUsage.isBalanceOnly(profile) ? AccountUsage.isOutOfBalance(usage) : AccountUsage.isBlockedBySession(usage)
    }

    private var subtitle: String {
        if isExpired { return "accounts.session_expired".localized }
        guard let usage else { return profile.providerLabel }
        if AccountUsage.isBalanceOnly(profile) {
            // The account name already says which service this is.
            if AccountUsage.isOutOfBalance(usage) { return "accounts.balance_empty".localized }
            if usage.sessionResetTime > Date() {
                return String(format: "accounts.credits_refill".localized, usage.sessionResetTime.formatted(.relative(presentation: .named)))
            }
            if let reserved = usage.overageBalance, reserved > 0, AccountUsage.isCredits(usage) {
                return String(format: "accounts.credits_reserved".localized, reserved.formatted(.number.precision(.fractionLength(0...2))))
            }
            return "accounts.balance_available".localized
        }
        if AccountUsage.isBlockedBySession(usage) {
            return String(format: "accounts.blocked_until".localized, usage.sessionResetTime.formatted(date: .omitted, time: .shortened))
        }
        if let reset = AccountUsage.relevantReset(usage) {
            return "\(profile.providerLabel) · " + String(format: "accounts.resets".localized, reset.formatted(.relative(presentation: .named)))
        }
        return profile.providerLabel
    }
}

// MARK: - Details

struct AccountDetails: View {
    let usage: ClaudeUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            UsageMeter(title: "accounts.session".localized, percent: usage.effectiveSessionPercentage, resetsAt: usage.sessionResetTime)
            if AccountUsage.hasWeeklyLimit(usage) {
                UsageMeter(title: "accounts.weekly".localized, percent: usage.weeklyPercentage, resetsAt: usage.weeklyResetTime)
            }
            ExtraUsageRow(usage: usage)
        }
        .padding(.top, 2)
    }
}

struct UsageMeter: View {
    let title: String
    let percent: Double
    let resetsAt: Date

    private var value: Double { min(max(percent, 0), 100) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                if resetsAt > Date() {
                    Text(resetsAt.formatted(.relative(presentation: .named)))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
                Text("\(Int(value.rounded()))%")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .frame(minWidth: 34, alignment: .trailing)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(AccountUsage.tint(value).gradient)
                        .frame(width: max(value > 0 ? 4 : 0, proxy.size.width * value / 100))
                }
            }
            .frame(height: 5)
            .animation(.smooth(duration: 0.5), value: value)
        }
    }
}

struct ExtraUsageRow: View {
    let usage: ClaudeUsage

    var body: some View {
        if let used = usage.costUsed, let limit = usage.costLimit, limit > 0 {
            let currency = (usage.costCurrency ?? "USD").uppercased()
            HStack(alignment: .firstTextBaseline) {
                Text("accounts.extra_usage".localized)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "accounts.extra_left".localized, Money.format(cents: max(limit - used, 0), currency: currency)))
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("/ \(Money.format(cents: limit, currency: currency))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
        if let balance = usage.overageBalance, balance > 0 {
            HStack(alignment: .firstTextBaseline) {
                Text("accounts.credit_balance".localized)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Money.format(cents: balance, currency: (usage.overageBalanceCurrency ?? "USD").uppercased()))
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.green)
            }
        }
    }
}

enum Money {
    /// claude.ai reports extra usage in minor units (cents).
    static func format(cents: Double, currency: String) -> String {
        (cents / 100).formatted(.currency(code: currency))
    }
}
