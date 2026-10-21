import Foundation

struct UsageSnapshot: Equatable {
    let fiveHour: Window
    let sevenDay: Window
    let sevenDaySonnet: Window?
    let sevenDayOpus: Window?
    let extraUsage: ExtraUsage?
    let fetchedAt: Date

    struct Window: Equatable {
        let utilization: Double   // percent 0–100 from the API (not 0–1)
        let resetsAt: Date?
    }

    struct ExtraUsage: Equatable {
        let isEnabled: Bool
        let monthlyLimit: Double   // stored in minor units (cents/centavos)
        let usedCredits: Double    // stored in minor units
        let utilization: Double    // percent 0–100, like Window.utilization
        let currency: String       // e.g. "BRL", "USD"

        var monthlyLimitMajor: Double { monthlyLimit / 100 }
        var usedCreditsMajor: Double { usedCredits / 100 }

        var currencySymbol: String {
            switch currency.uppercased() {
            case "USD": return "$"
            case "BRL": return "R$"
            case "EUR": return "€"
            case "GBP": return "£"
            default: return currency + " "
            }
        }
    }
}

/// Rendering of API utilization, which is a percentage **0–100** (not 0–1):
/// `1` means 1 %, never 100 %. The label rounds half away from zero
/// (`0.5` → "1 %", `0.4` → "0 %"); only the bar fraction is clamped to 0…1.
/// Non-finite or negative values render as 0.
enum UsagePercent {
    static func sanitized(_ u: Double) -> Double {
        u.isFinite ? min(max(u, 0), 100_000) : 0
    }

    static func label(_ u: Double) -> String {
        L10n.percent("\(Int(sanitized(u).rounded(.toNearestOrAwayFromZero)))")
    }

    static func fraction(_ u: Double) -> Double {
        min(sanitized(u) / 100, 1)
    }
}
