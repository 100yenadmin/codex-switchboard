import AppKit
import SwiftUI

// MARK: - Quota Window

struct QuotaWindow: Identifiable, Equatable, Codable {
    enum Kind: String, Codable {
        case fiveHour
        case daily
        case weekly
        case monthly
        case other
    }

    let kind: Kind
    let usedPercent: Double
    let resetSeconds: Double
    let durationSeconds: Double?

    var id: String {
        "\(kind.rawValue):\(Int(durationSeconds ?? 0))"
    }

    var freePercent: Double {
        max(0, min(100, 100 - usedPercent))
    }

    var shortLabel: String {
        switch kind {
        case .fiveHour: return "5h"
        case .daily: return "D"
        case .weekly: return "W"
        case .monthly: return "M"
        case .other: return "Q"
        }
    }

    var displayLabel: String {
        switch kind {
        case .fiveHour: return "5 hours"
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .other:
            guard let durationSeconds, durationSeconds > 0 else { return "Quota" }
            let hours = durationSeconds / 3_600
            if hours < 48 { return "\(Int(hours.rounded())) hours" }
            return "\(Int((hours / 24).rounded())) days"
        }
    }

    var sortOrder: Int {
        switch kind {
        case .fiveHour: return 0
        case .daily: return 1
        case .weekly: return 2
        case .monthly: return 3
        case .other: return 4
        }
    }
}

// MARK: - Account

struct Account: Identifiable, Equatable, Codable {
    let id: String          // dedup key: "email|accountId"
    let profileKey: String?
    let email: String
    let workspace: String   // team name or plan type
    let plan: String
    let sessionFree: Double // 0-100 (% remaining)
    let weeklyFree: Double
    let sessionResetSeconds: Double
    let weeklyResetSeconds: Double
    /// Nil means a pre-window-model snapshot. An empty array means the current response had no windows.
    let quotaWindows: [QuotaWindow]?
    var planRenewalDate: Date?
    let hasError: Bool
    let errorMessage: String?

    init(
        id: String,
        profileKey: String?,
        email: String,
        workspace: String,
        plan: String,
        sessionFree: Double,
        weeklyFree: Double,
        sessionResetSeconds: Double,
        weeklyResetSeconds: Double,
        quotaWindows: [QuotaWindow]? = nil,
        planRenewalDate: Date?,
        hasError: Bool,
        errorMessage: String?
    ) {
        self.id = id
        self.profileKey = profileKey
        self.email = email
        self.workspace = workspace
        self.plan = plan
        self.sessionFree = sessionFree
        self.weeklyFree = weeklyFree
        self.sessionResetSeconds = sessionResetSeconds
        self.weeklyResetSeconds = weeklyResetSeconds
        self.quotaWindows = quotaWindows
        self.planRenewalDate = planRenewalDate
        self.hasError = hasError
        self.errorMessage = errorMessage
    }

    var emailPrefix: String {
        email.components(separatedBy: "@").first ?? email
    }

    var accountID: String {
        let pieces = id.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return "" }
        return String(pieces[1])
    }

    var effectiveQuotaWindows: [QuotaWindow] {
        if let quotaWindows {
            return quotaWindows.sorted {
                if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                return ($0.durationSeconds ?? 0) < ($1.durationSeconds ?? 0)
            }
        }

        return [
            QuotaWindow(
                kind: .fiveHour,
                usedPercent: 100 - sessionFree,
                resetSeconds: sessionResetSeconds,
                durationSeconds: 18_000
            ),
            QuotaWindow(
                kind: .weekly,
                usedPercent: 100 - weeklyFree,
                resetSeconds: weeklyResetSeconds,
                durationSeconds: 604_800
            ),
        ]
    }

    var leadingQuotaWindow: QuotaWindow? {
        effectiveQuotaWindows.first { $0.kind != .weekly }
    }

    var weeklyQuotaWindow: QuotaWindow? {
        effectiveQuotaWindows.first { $0.kind == .weekly }
    }

    var quotaScore: Double {
        effectiveQuotaWindows.map(\.freePercent).min() ?? 0
    }

    /// Any reported quota window is exhausted; errors use the same waiting-row styling.
    var isWeeklyExhausted: Bool {
        hasError || effectiveQuotaWindows.contains { $0.freePercent <= 0.001 }
    }

    var isFreePlan: Bool {
        plan.codexSwitchboardNormalized == "free"
    }

    var isFreeWaitingForReset: Bool {
        !hasError
            && isFreePlan
            && effectiveQuotaWindows.contains { $0.freePercent <= 0.001 }
            && freePlanResetSeconds > 0
    }

    var freePlanResetSeconds: Double {
        effectiveQuotaWindows
            .filter { $0.freePercent <= 0.001 && $0.resetSeconds > 0 }
            .map(\.resetSeconds)
            .min() ?? 0
    }

    var nextWaitingResetSeconds: Double {
        let exhausted = effectiveQuotaWindows
            .filter { $0.freePercent <= 0.001 && $0.resetSeconds > 0 }
            .map(\.resetSeconds)
            .min()
        if let exhausted { return exhausted }
        return effectiveQuotaWindows
            .filter { $0.resetSeconds > 0 }
            .map(\.resetSeconds)
            .min() ?? Double.greatestFiniteMagnitude
    }

    var isUsableForCodex: Bool {
        !hasError
            && !effectiveQuotaWindows.isEmpty
            && effectiveQuotaWindows.allSatisfy { $0.freePercent > 0.001 }
    }

    /// Hours until weekly window resets (from API `reset_after_seconds`).
    var hoursUntilWeeklyReset: Double {
        max(0, (weeklyQuotaWindow?.resetSeconds ?? 0) / 3600)
    }

    /// Highlight reset text when meaningful balance expires soon.
    var isWeeklyResetUrgent: Bool {
        guard let weeklyQuotaWindow else { return false }
        return isUsableForCodex
            && weeklyQuotaWindow.freePercent >= 20
            && hoursUntilWeeklyReset < 12
    }

    /// Top priority strip: useful balance that resets in less than 24 hours.
    var isWeeklyPriority: Bool {
        guard let weeklyQuotaWindow else { return false }
        return isUsableForCodex
            && quotaScore >= 20
            && weeklyQuotaWindow.freePercent >= 20
            && hoursUntilWeeklyReset < 24
    }

    var planDaysRemaining: Int? {
        guard let planRenewalDate else { return nil }
        return max(0, Int(ceil(planRenewalDate.timeIntervalSinceNow / 86_400)))
    }
}

// MARK: - Enums

enum ListDensity: String {
    case expanded
    case compact
}

enum AccountInformationMode: String {
    case complete
    case focused
}

enum ResetTextScale {
    static let defaultPercent = 100
    static let minimumPercent = 80
    static let maximumPercent = 200
    static let stepPercent = 10
    static let presets = [100, 125, 150]

    static func clampedPercent(_ percent: Int) -> Int {
        min(max(percent, minimumPercent), maximumPercent)
    }

    static func nearestPresetPercent(to percent: Int) -> Int {
        presets.min { abs($0 - percent) < abs($1 - percent) } ?? defaultPercent
    }

    static func scale(for percent: Int) -> CGFloat {
        CGFloat(clampedPercent(percent)) / 100
    }

    static func stepped(_ percent: Int, by delta: Int) -> Int {
        clampedPercent(percent + delta)
    }
}

extension String {
    fileprivate var codexSwitchboardNormalized: String {
        trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var isGenericWorkspaceName: Bool {
        let trimmed = codexSwitchboardNormalized
        return trimmed == "team" || trimmed == "plus" || trimmed == "pro" || trimmed == "free" || trimmed == "?"
    }

    var isPersonalPlanType: Bool {
        let trimmed = codexSwitchboardNormalized
        return trimmed == "plus" || trimmed == "pro" || trimmed == "free" || trimmed == "personal" || trimmed == "individual"
    }

    var isUnknownPlanType: Bool {
        let trimmed = codexSwitchboardNormalized
        return trimmed.isEmpty || trimmed == "?"
    }

    var isLikelyPersonalAccountID: Bool {
        codexSwitchboardNormalized.hasPrefix("user-")
    }
}

// MARK: - Theme

struct Theme {
    /// Bar fill color based on % free remaining.
    static func barColor(for pct: Double) -> Color {
        switch pct {
        case 50...:       return Color(hex: "30D158")   // green
        case 20..<50:     return Color(lightHex: "8A6A00", darkHex: "FFD60A")   // yellow
        case 5..<20:      return Color(hex: "FF9F0A")   // orange
        case 0.001..<5:   return Color(hex: "FF453A")   // red
        default:          return Color(hex: "8E8E93")   // gray (0 %)
        }
    }

    /// Weekly bar when quota is exhausted: neutral gray, not alert red.
    static let weeklyExhaustedBar = Color(hex: "8E8E93")

    /// Workspace chip background.
    static func workspaceColor(for ws: String) -> Color {
        let stableIndex = ws.lowercased().unicodeScalars.reduce(0) { partial, scalar in
            (partial &* 31 &+ Int(scalar.value)) & 0x7fffffff
        }
        switch stableIndex % 6 {
        case 0: return Color(hex: "5F80A8")
        case 1: return Color(hex: "6F9277")
        case 2: return Color(hex: "8A6F9B")
        case 3: return Color(hex: "A7666E")
        case 4: return Color(hex: "AF8158")
        default: return Color(hex: "7871A6")
        }
    }

    /// Workspace chip text (black or white for contrast).
    static func workspaceTextColor(for ws: String) -> Color {
        Color.white.opacity(0.96)
    }
}

// MARK: - Color Helper

extension Color {
    init(lightHex: String, darkHex: String) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? darkHex : lightHex)
        })
    }

    init(hex: String) {
        let h = hex.trimmingCharacters(in: .alphanumerics.inverted)
        var n: UInt64 = 0
        Scanner(string: h).scanHexInt64(&n)
        let r, g, b, a: UInt64
        switch h.count {
        case 6: (a, r, g, b) = (255, n >> 16, n >> 8 & 0xFF, n & 0xFF)
        case 8: (a, r, g, b) = (n >> 24, n >> 16 & 0xFF, n >> 8 & 0xFF, n & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(.sRGB,
                  red:     Double(r) / 255,
                  green:   Double(g) / 255,
                  blue:    Double(b) / 255,
                  opacity: Double(a) / 255)
    }
}

private extension NSColor {
    convenience init(hex: String) {
        let h = hex.trimmingCharacters(in: .alphanumerics.inverted)
        var n: UInt64 = 0
        Scanner(string: h).scanHexInt64(&n)
        let r, g, b, a: UInt64
        switch h.count {
        case 6: (a, r, g, b) = (255, n >> 16, n >> 8 & 0xFF, n & 0xFF)
        case 8: (a, r, g, b) = (n >> 24, n >> 16 & 0xFF, n >> 8 & 0xFF, n & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(srgbRed: Double(r) / 255,
                  green:   Double(g) / 255,
                  blue:    Double(b) / 255,
                  alpha:   Double(a) / 255)
    }
}

// MARK: - Reset Formatter

struct ResetFormatter {
    private static let weekdaysShort = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    /// Weekly exhausted row: "resets Wed 18:19" because reset is the only actionable info.
    static func formatReset(seconds: Double) -> String {
        let inner = format(seconds: seconds)
        if inner == "now" { return "resets now" }
        return "resets \(inner)"
    }

    /// Short context-aware string.
    static func format(seconds: Double) -> String {
        guard seconds > 0 else { return "now" }
        let now = Date()
        let tgt = now.addingTimeInterval(seconds)
        let cal = Calendar.current
        let t   = hhmm(tgt)
        if cal.isDateInToday(tgt) { return t }
        if cal.isDateInTomorrow(tgt) { return "tomorrow \(t)" }
        if isSameWeekStartingSunday(now, tgt) {
            let wd = cal.component(.weekday, from: tgt)
            return "\(weekdaysShort[wd - 1]) \(t)"
        }
        return dateTimeString(target: tgt, now: now, time: t)
    }

    static func formatFreeReturn(seconds: Double) -> String {
        guard seconds > 0 else { return "now" }
        let now = Date()
        let tgt = now.addingTimeInterval(seconds)
        let cal = Calendar.current
        let t = hhmm(tgt)
        if cal.isDateInToday(tgt) { return "today \(t)" }
        if cal.isDateInTomorrow(tgt) { return "tomorrow \(t)" }
        return dateTimeString(target: tgt, now: now, time: t)
    }

    static func timeOnly(seconds: Double) -> String {
        guard seconds > 0 else { return "now" }
        return hhmm(Date().addingTimeInterval(seconds))
    }

    private static func startOfWeekSunday(containing date: Date) -> Date {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: date)
        let weekday = cal.component(.weekday, from: dayStart)
        return cal.date(byAdding: .day, value: -(weekday - 1), to: dayStart) ?? dayStart
    }

    private static func isSameWeekStartingSunday(_ a: Date, _ b: Date) -> Bool {
        let cal = Calendar.current
        let sa = startOfWeekSunday(containing: a)
        let sb = startOfWeekSunday(containing: b)
        return cal.isDate(sa, inSameDayAs: sb)
    }

    private static func dateTimeString(target: Date, now: Date, time: String) -> String {
        "\(dateString(target: target, now: now)) \(time)"
    }

    private static func dateString(target: Date, now: Date) -> String {
        let cal = Calendar.current
        let d = cal.component(.day, from: target)
        let m = cal.component(.month, from: target)
        let y = cal.component(.year, from: target)
        let yNow = cal.component(.year, from: now)
        if y == yNow {
            return String(format: "%02d/%02d", d, m)
        }
        return String(format: "%02d/%02d/%d", d, m, y)
    }

    /// Full tooltip string.
    static func fullTooltip(seconds: Double) -> String {
        guard seconds > 0 else { return "Now" }
        let tgt = Date().addingTimeInterval(seconds)
        return tooltipFormatter.string(from: tgt)
    }

    static func fullTooltip(date: Date) -> String {
        tooltipFormatter.string(from: date)
    }

    private static func hhmm(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }

    private static let tooltipFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE, MMMM d 'at' HH:mm"
        return f
    }()
}

struct PlanCycleFormatter {
    static func daysText(for account: Account) -> String? {
        guard let days = account.planDaysRemaining else { return nil }
        return "\(days)D"
    }

    static func tooltip(for date: Date) -> String {
        "Plan renews \(ResetFormatter.fullTooltip(date: date))"
    }
}
