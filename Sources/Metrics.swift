import SwiftUI

// ── Ansichten, oben rechts umschaltbar ───────────────────────────
enum AppLayout: String, CaseIterable, Identifiable {
    case standard, dials, focus, tuning

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "Standard"
        case .dials:    return "Rundinstrumente"
        case .focus:    return "Fokus"
        case .tuning:   return "Abstimmung"
        }
    }

    var symbol: String {
        switch self {
        case .standard: return "rectangle.grid.1x2"
        case .dials:    return "speedometer"
        case .focus:    return "scope"
        case .tuning:   return "chart.xyaxis.line"
        }
    }
}

// ── Ein Messwert mit allem, was die Ansichten zum Darstellen brauchen ──
enum Metric: String, CaseIterable, Identifiable {
    case lambda, rpm, oilP, oilT, tank, advance, voltage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lambda:  return "Lambda"
        case .rpm:     return "Drehzahl"
        case .oilP:    return "Öldruck"
        case .oilT:    return "Öltemperatur"
        case .tank:    return "Tank"
        case .advance: return "Zündwinkel"
        case .voltage: return "Bordnetz"
        }
    }

    var unit: String {
        switch self {
        case .lambda:  return ""
        case .rpm:     return "U/min"
        case .oilP:    return "bar"
        case .oilT:    return "°C"
        case .tank:    return "%"
        case .advance: return "°"
        case .voltage: return "V"
        }
    }

    var format: String {
        switch self {
        case .lambda:            return "%.3f"
        case .rpm, .tank:        return "%.0f"
        case .oilP:              return "%.2f"
        case .oilT, .advance, .voltage: return "%.1f"
        }
    }

    var placeholder: String {
        switch self {
        case .lambda:  return "-.---"
        case .rpm:     return "----"
        case .oilP:    return "-.--"
        case .tank:    return "--"
        case .oilT, .advance, .voltage: return "--.-"
        }
    }

    /// Bridge-Werte kommen 10x/s, die 123 seltener -> traegere Feder
    var motion: Animation {
        switch self {
        case .lambda, .oilP, .oilT, .tank: return Motion.value
        case .rpm, .advance, .voltage:     return Motion.slow
        }
    }

    /// Drehzahl waehrend der Bewegung in 10er-Schritten, sonst normal formatiert
    var render: ((Double) -> String)? {
        guard self == .rpm else { return nil }
        return { v in String(format: "%.0f", (v / 10).rounded() * 10) }
    }

    // Massstab im Verlauf
    var range: ClosedRange<Double> {
        switch self {
        case .lambda:  return 0.80...1.20
        case .rpm:     return 0...Limits.rpmScaleMax
        case .oilP:    return 0...6
        case .oilT:    return 40...160
        case .tank:    return 0...100
        case .advance: return 0...40
        case .voltage: return 11...15.5
        }
    }

    var gridLines: [Double] {
        switch self {
        case .lambda:  return [0.9, 1.0, 1.1]
        case .rpm:     return [2000, 4000, 6000]
        case .oilP:    return [2, 4]
        case .oilT:    return [60, 100, 140]
        case .tank:    return [25, 50, 75]
        case .advance: return [10, 20, 30]
        case .voltage: return [12, 13, 14, 15]
        }
    }

    var gridFormat: String { self == .lambda ? "%.1f" : "%.0f" }

    /// Aktueller Wert; nil = keine Daten oder Sensorfehler
    func current(_ ble: BLEManager) -> Double? {
        switch self {
        case .lambda:  return ble.shown.flatMap { $0.lambda <= 2 ? $0.lambda : nil }
        case .rpm:     return ble.tune?.rpm
        case .oilP:    return ble.shown.flatMap { $0.pressure >= 0 ? $0.pressure : nil }
        case .oilT:    return ble.shown.flatMap { $0.temp >= 0 ? $0.temp : nil }
        case .tank:    return ble.shown?.tankValue
        case .advance: return ble.tune?.advance
        case .voltage: return ble.tune?.voltage
        }
    }

    func value(in s: Sample) -> Double? {
        switch self {
        case .lambda:  return s.lambda
        case .rpm:     return s.rpm
        case .oilP:    return s.oilP
        case .oilT:    return s.oilT
        case .tank:    return s.tank
        case .advance: return s.advance
        case .voltage: return s.voltage
        }
    }

    /// "---" bei Sensorfehler (-1 vom Arduino), sonst der normale Platzhalter
    func placeholderText(_ ble: BLEManager) -> String {
        switch self {
        case .oilP:
            if let p = ble.shown?.pressure, p < 0 { return "---" }
        case .oilT:
            if let t = ble.shown?.temp, t < 0 { return "---" }
        default:
            break
        }
        return placeholder
    }

    /// Bewertung wie im C6-Display
    func judge(_ v: Double?) -> (Level, String) {
        guard let v else { return (.off, "") }
        switch self {
        case .lambda:  return Limits.lambda(v)
        case .rpm:     return (Limits.rpm(v), "")
        case .oilP:    return Limits.pressure(v)
        case .oilT:    return Limits.temperature(v)
        case .tank:    return Limits.tank(v)
        case .advance: return (.info, "vor OT")
        case .voltage: return Limits.voltage(v)
        }
    }

    /// Statuszeile; bei Fehlern der Hinweis, sonst Zusatzwerte der 123
    func status(_ ble: BLEManager) -> String {
        if case .oilP = self, let p = ble.shown?.pressure, p < 0 { return "Sensor / Kabel prüfen" }
        if case .oilT = self, let t = ble.shown?.temp, t < 0 { return "Sensor / Kabel prüfen" }
        switch self {
        case .advance:
            if let m = ble.tune?.mapKPa { return String(format: "vor OT · Saugrohr %.0f kPa", m) }
        case .voltage:
            var parts: [String] = []
            if let c = ble.tune?.coilCurrent { parts.append(String(format: "Spule %.1f A", c)) }
            if let t = ble.tune?.moduleTemp { parts.append(String(format: "Modul %.0f °C", t)) }
            if !parts.isEmpty { return parts.joined(separator: " · ") }
        default:
            break
        }
        return judge(current(ble)).1
    }

    /// Linienfarbe im Verlauf
    func lineColor(_ v: Double) -> Color {
        let l = judge(v).0
        return l == .info ? Theme.accent : l.color
    }
}
