import SwiftUI

// Farben wie auf dem ESP32-C6-Display (v18/v19) und in der Web-App
extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue:  Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

enum Theme {
    /// Nachtmodus: dunkler, warmer Ton, blendet nicht. Gesetzt vom AppModel;
    /// die Oberflaeche wird beim Umschalten komplett neu aufgebaut.
    static var night = false

    private static func pick(_ day: UInt32, _ dark: UInt32) -> Color { Color(hex: night ? dark : day) }

    static var bg: Color         { pick(0x0D0D0D, 0x000000) }
    static var bgNoSignal: Color { pick(0x2A0A0A, 0x1A0505) }   // roetlich bei Signalverlust, wie im Display
    static var surface: Color    { pick(0x14141F, 0x0F0907) }
    static var surface2: Color   { pick(0x1A1A2E, 0x1A0F0B) }
    static var line: Color       { pick(0x2A2A3A, 0x2A1A14) }
    static var fg: Color         { pick(0xECECF3, 0xE8A07C) }
    static var muted: Color      { pick(0x8A8A9C, 0x8C5E4C) }
    static var accent: Color     { pick(0xFD8C00, 0xD9690A) }
    static var dialFace: Color   { pick(0x101018, 0x0A0605) }   // Zifferblatt der Rundinstrumente
    static var load: Color       { pick(0x40C4FF, 0x2E7FA8) }   // wenig Last in der Punktewolke
    static var ok: Color         { pick(0x2ECC71, 0x4FA83A) }
    static var warn: Color       { pick(0xF1C40F, 0xC99A06) }
    static var crit: Color       { pick(0xE74C3C, 0xE0362B) }
}

enum Level {
    case ok, warn, crit, off
    case info   // Messwert ohne Bewertung (Drehzahl, Zuendwinkel …)

    /// Farbe der Zahl
    var color: Color {
        switch self {
        case .ok:   return Theme.ok
        case .warn: return Theme.warn
        case .crit: return Theme.crit
        case .off:  return Theme.muted
        case .info: return Theme.fg
        }
    }

    /// Farbe des Streifens links an der Karte
    var stripe: Color { self == .info ? Theme.accent : color }
}

// Grenzwerte 1:1 aus dem C6-Code (colLam, colOilP, colOilT, colTank)
enum Limits {
    static func lambda(_ l: Double) -> (Level, String) {
        if l > 2     { return (.off,  "Sonde nicht bereit") }
        if l < 0.94  { return (.crit, "Fett") }
        if l < 0.98  { return (.warn, "leicht fett") }
        if l <= 1.02 { return (.ok,   "Stöchiometrisch") }
        if l <= 1.06 { return (.warn, "leicht mager") }
        return (.crit, "Mager")
    }

    static func pressure(_ p: Double) -> (Level, String) {
        if p < 0   { return (.off,  "Sensor / Kabel prüfen") }
        if p < 1.0 { return (.crit, "zu niedrig") }
        if p < 2.0 { return (.warn, "niedrig") }
        return (.ok, "normal")
    }

    static func temperature(_ t: Double) -> (Level, String) {
        if t < 0   { return (.off,  "Sensor / Kabel prüfen") }
        if t < 60  { return (.off,  "nicht betriebswarm") }
        if t < 130 { return (.ok,   "normal") }
        if t < 145 { return (.warn, "erhöht") }
        return (.crit, "kritisch")
    }

    static func tank(_ v: Double) -> (Level, String) {
        if v < 15 { return (.crit, "Reserve") }
        if v < 30 { return (.warn, "niedrig") }
        return (.ok, "")
    }

    // ── 123ignition ── Grenzen fuer den 2CV6, bei Bedarf anpassen
    static let rpmScaleMax: Double = 6500
    static let rpmWarn: Double     = 5000
    static let rpmCrit: Double     = 5750   // Nenndrehzahl 2CV6

    static func rpm(_ r: Double) -> Level {
        if r >= rpmCrit { return .crit }
        if r >= rpmWarn { return .warn }
        return .info
    }

    // Aufloesung der 123 ist grob (ca. 0,22 V pro Schritt)
    static func voltage(_ v: Double) -> (Level, String) {
        if v < 11.8 { return (.crit, "niedrig") }
        if v < 12.4 { return (.warn, "lädt nicht?") }
        if v > 15.2 { return (.crit, "zu hoch") }
        if v > 14.8 { return (.warn, "hoch") }
        return (.ok, "")
    }

    static func moduleTemp(_ t: Double) -> Level {
        if t >= 100 { return .crit }
        if t >= 85  { return .warn }
        return .info
    }
}
