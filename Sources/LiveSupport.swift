import SwiftUI

// ── Bewertung der Live-Werte im Zusammenhang ─────────────────────
// Lambda wird gegen das Ziel des aktuellen Betriebsbereichs bewertet
// (Leerlauf, Teillast, Vollgas …), Oeldruck und Bordnetz je nachdem, ob der
// Motor laeuft. Ohne 123 fehlen Drehzahl und Last, dann gelten die festen
// Grenzen wie auf dem Display im Auto.

extension SettingKey {
    static let lambdaByTarget = "lambdaByTarget"
    static let idleTargetRPM = "idleTargetRPM"
}

extension Severity {
    var level: Level {
        switch self {
        case .none: return .off
        case .info: return .info
        case .ok:   return .ok
        case .warn: return .warn
        case .crit: return .crit
        }
    }

    var symbol: String {
        switch self {
        case .none: return "circle.dashed"
        case .info: return "info.circle.fill"
        case .ok:   return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .crit: return "exclamationmark.octagon.fill"
        }
    }
}

/// Zwischenspeicher der Einstellungen, damit die Anzeigen nicht 10-mal je
/// Sekunde in den UserDefaults lesen. Das AppModel laedt bei jeder Aenderung neu.
enum LiveContext {
    static var targets = MixtureTargets.load()
    static var byTarget = true
    static var idleTargetRPM = 850.0
    static var alerts = AlertSettings.load()
    static var vehicle = Vehicle.load()

    static func reload() {
        let d = UserDefaults.standard
        targets = MixtureTargets.load(from: d)
        byTarget = d.object(forKey: SettingKey.lambdaByTarget) as? Bool ?? true
        let rpm = d.double(forKey: SettingKey.idleTargetRPM)
        idleTargetRPM = rpm >= 500 && rpm <= 1400 ? rpm : 850
        alerts = AlertSettings.load(from: d)
        vehicle = Vehicle.load(from: d)
    }
}

struct LambdaLook {
    var level: Level
    var text: String
    var target: Double?          // Ziel des aktuellen Bereichs, nil = feste Zonen um 1,00
}

enum LiveJudge {
    /// Lambda mit Drehzahl und Saugrohrdruck der 123, sonst nach festen Grenzen
    static func lambda(_ v: Double?, rpm: Double?, kPa: Double?) -> LambdaLook {
        guard let v else { return LambdaLook(level: .off, text: "keine Daten", target: nil) }
        if v > 2 { return LambdaLook(level: .off, text: "Sonde nicht bereit", target: nil) }
        if let r = rpm, r < 300 { return LambdaLook(level: .info, text: "Motor steht", target: nil) }
        if LiveContext.byTarget, let j = MixtureJudge.live(lambda: v, rpm: rpm, kPa: kPa, targets: LiveContext.targets) {
            let area = j.regime?.title ?? ""
            let text = j.target == nil ? area : area + " · " + j.text
            return LambdaLook(level: j.severity.level, text: text, target: j.target)
        }
        let fixed = Limits.lambda(v)
        return LambdaLook(level: fixed.0, text: fixed.1, target: nil)
    }

    /// Farbe eines Lambda-Werts im Verlauf oder in der Punktewolke
    static func lambdaColor(_ v: Double, rpm: Double?, kPa: Double?) -> Color {
        let l = lambda(v, rpm: rpm, kPa: kPa).level
        return l == .info ? Theme.muted : l.color
    }
}

extension BLEManager {
    var lambdaLook: LambdaLook {
        LiveJudge.lambda(shown?.lambda, rpm: tune?.rpm, kPa: tune?.mapKPa)
    }
}

extension Metric {
    /// Bewertung mit dem, was die 123 gerade meldet
    func judge(_ v: Double?, _ ble: BLEManager) -> (Level, String) {
        guard let v else { return (.off, "") }
        switch self {
        case .lambda:
            let l = ble.lambdaLook
            return (l.level, l.text)
        case .oilP:
            let j = ContextJudge.pressure(v, rpm: ble.tune?.rpm)
            return (j.0.level, j.1)
        case .voltage:
            let j = ContextJudge.voltage(v, rpm: ble.tune?.rpm)
            return (j.0.level, j.1)
        default:
            return judge(v)
        }
    }
}

// ── Warnung ueber den Anzeigen ───────────────────────────────────
struct AlertBanner: View {
    let alert: ActiveAlert

    var body: some View {
        let color = alert.kind.severity == .crit ? Theme.crit : Theme.warn
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: alert.kind.severity.symbol)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.kind.title + " · " + alert.detail)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Theme.fg)
                Text(alert.kind.advice)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.fg.opacity(0.85))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(color.opacity(0.22))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(color.opacity(0.7), lineWidth: 1.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Zeigt die wichtigste aktive Warnung, sonst nichts
struct AlertArea: View {
    @ObservedObject var alerts: AlertCenter

    var body: some View {
        if let a = alerts.top {
            AlertBanner(alert: a)
                .transition(.opacity)
        }
    }
}

/// Kleines Etikett in Statusfarbe
struct Chip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(color)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule())
    }
}

extension Severity {
    var color: Color { level == .info ? Theme.muted : level.color }
}
