//
//  AccountsMenuBarRenderer.swift
//  Aitracker
//
//  The single menu bar item: either a plain icon, or one small fill bar per
//  account showing how "used up" that account is.
//

import AppKit

enum MenuBarStyle: String, CaseIterable {
    case icon
    case bars

    private static let key = "aitracker.menuBarStyle"

    static var current: MenuBarStyle {
        get { MenuBarStyle(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .bars }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

enum AccountsMenuBarRenderer {
    static func effectiveUsage(_ usage: ClaudeUsage?) -> Double {
        AccountUsage.effective(usage)
    }

    static func color(for percent: Double) -> NSColor {
        switch percent {
        case ..<70: return .systemGreen
        case ..<90: return .systemOrange
        default: return .systemRed
        }
    }

    static func image(accounts: [Profile], style: MenuBarStyle, darkMenuBar: Bool) -> NSImage {
        if style == .icon || accounts.isEmpty {
            return appIcon()
        }
        return bars(accounts: accounts, darkMenuBar: darkMenuBar)
    }

    // MARK: Icon only

    /// Monochrome version of the app logo: three concentric open gauge arcs.
    private static func appIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let center = NSPoint(x: 9, y: 8.6)
            let rings: [(r: CGFloat, fill: CGFloat)] = [(7.2, 0.82), (4.9, 0.58), (2.6, 0.36)]
            NSColor.black.setStroke()
            for ring in rings {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: ring.r, startAngle: 225, endAngle: 225 - 270 * ring.fill, clockwise: true)
                arc.lineWidth = 1.7
                arc.lineCapStyle = .round
                arc.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: Bars side by side

    private static let barWidth: CGFloat = 6
    private static let barHeight: CGFloat = 15
    private static let letterWidth: CGFloat = 8
    private static let groupGap: CGFloat = 6
    private static let height: CGFloat = 18

    private static let balanceFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)

    private static func balanceText(_ account: Profile) -> NSString {
        AccountUsage.shortBalance(account.claudeUsage) as NSString
    }

    private static func groupWidth(_ account: Profile) -> CGFloat {
        if AccountUsage.isBalanceOnly(account) {
            return letterWidth + 2 + ceil(balanceText(account).size(withAttributes: [.font: balanceFont]).width)
        }
        return letterWidth + 2 + barWidth
    }

    private static func bars(accounts: [Profile], darkMenuBar: Bool) -> NSImage {
        let widths = accounts.map(groupWidth)
        let width = widths.reduce(0, +) + CGFloat(max(accounts.count - 1, 0)) * groupGap
        let foreground: NSColor = darkMenuBar ? .white : .black

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            var x: CGFloat = 0
            let barY = (height - barHeight) / 2

            for account in accounts {
                // Account initial, in the account's color
                let letter = String(account.name.prefix(1)).uppercased() as NSString
                let letterColor = AccountPalette.nsColor(for: account, in: accounts)
                    .blended(withFraction: darkMenuBar ? 0.25 : 0, of: .white) ?? foreground
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: letterColor]
                let size = letter.size(withAttributes: attrs)
                letter.draw(at: NSPoint(x: x + (letterWidth - size.width) / 2, y: (height - size.height) / 2), withAttributes: attrs)
                x += letterWidth + 2

                if AccountUsage.isBalanceOnly(account) {
                    // Prepaid balance (DeepSeek): show the amount; red when empty.
                    let text = balanceText(account)
                    let textColor: NSColor = AccountUsage.isOutOfBalance(account.claudeUsage) ? .systemRed : foreground
                    let textAttrs: [NSAttributedString.Key: Any] = [.font: balanceFont, .foregroundColor: textColor]
                    let textSize = text.size(withAttributes: textAttrs)
                    text.draw(at: NSPoint(x: x, y: (height - textSize.height) / 2), withAttributes: textAttrs)
                    x += ceil(textSize.width) + groupGap
                    continue
                }

                // Track
                let track = NSRect(x: x, y: barY, width: barWidth, height: barHeight)
                let trackPath = NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2)
                foreground.withAlphaComponent(0.25).setFill()
                trackPath.fill()

                // Fill from the bottom up
                let percent = effectiveUsage(account.claudeUsage)
                if percent > 0 {
                    let fillHeight = max(2, barHeight * CGFloat(percent / 100))
                    NSGraphicsContext.saveGraphicsState()
                    trackPath.addClip()
                    color(for: percent).setFill()
                    NSRect(x: x, y: barY, width: barWidth, height: fillHeight).fill()
                    NSGraphicsContext.restoreGraphicsState()
                }

                x += barWidth + groupGap
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
