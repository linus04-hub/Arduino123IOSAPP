import SwiftUI
import AppKit
import Charts

// ── Bausteine der Oberflaeche ────────────────────────────────────

extension Severity {
    var tint: Color {
        switch self {
        case .none: return .secondary
        case .info: return .secondary
        case .ok:   return .green
        case .warn: return .orange
        case .crit: return .red
        }
    }

    var icon: String {
        switch self {
        case .none: return "circle.dashed"
        case .info: return "info.circle.fill"
        case .ok:   return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .crit: return "exclamationmark.octagon.fill"
        }
    }
}

extension Regime {
    /// Feste Farbe je Bereich fuer Diagramme
    var tint: Color {
        switch self {
        case .idle:       return Color(red: 0.55, green: 0.60, blue: 0.70)
        case .cruise:     return Color(red: 0.20, green: 0.70, blue: 0.45)
        case .transition: return Color(red: 0.15, green: 0.65, blue: 0.80)
        case .fullLow:    return Color(red: 0.95, green: 0.60, blue: 0.10)
        case .fullHigh:   return Color(red: 0.88, green: 0.25, blue: 0.20)
        case .overrun:    return Color(red: 0.60, green: 0.45, blue: 0.85)
        }
    }

    static let judged: [Regime] = [.idle, .cruise, .transition, .fullLow, .fullHigh]
}

extension Channel {
    var tint: Color {
        switch self {
        case .lambda:     return .primary
        case .rpm:        return .orange
        case .map:        return Color(red: 0.25, green: 0.65, blue: 0.95)
        case .advance:    return .purple
        case .oilT:       return .red
        case .oilP:       return .yellow
        case .speed:      return .green
        case .voltage:    return .teal
        case .tank:       return .brown
        case .coil:       return .mint
        case .moduleTemp: return .pink
        }
    }
}

enum Fmt {
    private static let dayTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "EE dd.MM.yy, HH:mm"
        return f
    }()

    private static let dayOnly: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "dd.MM.yy"
        return f
    }()

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func date(_ d: Date) -> String { dayTime.string(from: d) }
    static func day(_ d: Date) -> String { dayOnly.string(from: d) }
    static func time(_ d: Date) -> String { clock.string(from: d) }

    static func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: Date())
    }

    static func num(_ v: Double?, _ digits: Int, unit: String = "") -> String {
        guard let v else { return "–" }
        let s = String(format: "%.\(digits)f", v)
        return unit.isEmpty ? s : s + " " + unit
    }

    static func signed(_ v: Double?, _ digits: Int) -> String {
        guard let v else { return "–" }
        return SignedText.of(v, digits)
    }
}

/// Karte mit Titel
struct Card<Content: View>: View {
    var title: String
    var symbol: String? = nil
    var trailing: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let s = symbol {
                    Image(systemName: s).foregroundStyle(.orange)
                }
                Text(title).font(.headline)
                Spacer()
                if let t = trailing { t }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1))
    }
}

/// Grosse Kennzahl
struct StatTile: View {
    var title: String
    var value: String
    var detail: String = ""
    var tint: Color = .primary
    var symbol: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                if let s = symbol { Image(systemName: s).font(.caption) }
                Text(title.uppercased()).font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1))
    }
}

struct PageHeader: View {
    var title: String
    var subtitle: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.largeTitle.weight(.semibold))
            if !subtitle.isEmpty {
                Text(subtitle).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EmptyHint: View {
    var text: String
    var symbol: String = "tray"

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, minHeight: 140)
    }
}

struct SeverityChip: View {
    var text: String
    var severity: Severity

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(severity.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(severity.tint.opacity(0.14)))
    }
}

/// Lambda je Bereich gegen das Ziel, als Tabelle
struct RegimeTable: View {
    var regimes: [String: RegimeStat]
    var targets: MixtureTargets
    var showShare = true

    var body: some View {
        // Ist die Karte schmal, fällt die Spalte mit dem Urteil weg.
        // Die Farbe der Abweichung sagt dann dasselbe.
        ViewThatFits(in: .horizontal) {
            table(chips: true)
            table(chips: false)
        }
    }

    private func table(chips: Bool) -> some View {
        let total = regimes.values.reduce(0) { $0 + $1.seconds }
        return Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
            GridRow {
                Text("Bereich")
                if showShare { Text("Anteil").gridColumnAlignment(.trailing) }
                Text("λ").gridColumnAlignment(.trailing)
                Text("Ziel").gridColumnAlignment(.trailing)
                Text("Abw.").gridColumnAlignment(.trailing)
                if chips { Text("") }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(Regime.allCases) { r in
                let st = regimes[r.rawValue]
                let l = st?.lambda
                let t = targets.target(r)
                let j = l.map { MixtureJudge.judge(lambda: $0, regime: r, targets: targets) }
                GridRow {
                    HStack(spacing: 6) {
                        Circle().fill(r.tint).frame(width: 8, height: 8)
                        Text(r.title)
                    }
                    if showShare {
                        Text(total > 0 ? String(format: "%.0f %%", (st?.seconds ?? 0) / total * 100) : "–")
                            .foregroundStyle(.secondary)
                    }
                    Text(Fmt.num(l, 3)).fontWeight(.semibold)
                    Text(Fmt.num(t, 2)).foregroundStyle(.secondary)
                    Text(l != nil && t != nil ? Fmt.signed(l! - t!, 3) : "–")
                        .foregroundStyle(j?.severity.tint ?? .secondary)
                        .help(j?.text ?? "")
                    if chips {
                        if let j, t != nil {
                            SeverityChip(text: j.text, severity: j.severity)
                        } else {
                            Text(l == nil ? "keine Daten" : "ohne Ziel").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .lineLimit(1)
                .monospacedDigit()
            }
        }
    }
}

/// Drehzahl-Achse ohne Tausenderpunkt und ohne abgeschnittene Zahl am Rand
struct RPMAxis: ViewModifier {
    func body(content: Content) -> some View {
        content.chartXAxis {
            AxisMarks(values: [1000.0, 2000, 3000, 4000, 5000, 6000]) { v in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    // die letzte Zahl stößt an die Lambda-Achse
                    if let d = v.as(Double.self) { Text(d < 5500 ? String(format: "%.0f", d) : "") }
                }
            }
        }
    }
}

extension View {
    func rpmAxis() -> some View { modifier(RPMAxis()) }
}

/// Speichern-Dialog fuer Text (CSV)
enum SaveText {
    @MainActor
    static func run(_ text: String, name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
