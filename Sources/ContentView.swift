import SwiftUI

struct ContentView: View {
    @ObservedObject var ble: BLEManager

    var body: some View {
        ZStack {
            (ble.noSignal ? Theme.bgNoSignal : Theme.bg)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.4), value: ble.noSignal)

            ScrollView {
                VStack(spacing: 10) {
                    header

                    if let w = ble.warning {
                        WarningBanner(text: w)
                    }

                    // ── Anzeige (Bridge) ──
                    LambdaCard(value: ble.shown?.lambda)

                    HStack(spacing: 10) {
                        pressureCard
                        temperatureCard
                    }

                    TankCard(value: ble.shown?.tankValue)

                    // ── Zuendung (123ignition) ──
                    SectionLabel(text: "Zündung · 123ignition")

                    if let w = ble.tuneWarning {
                        WarningBanner(text: w)
                    }

                    RPMCard(rpm: ble.tune?.rpm, status: rpmStatus)

                    HStack(spacing: 10) {
                        ValueCard(title: "Zündwinkel", symbol: "bolt.fill", unit: "°",
                                  text: format(ble.tune?.advance, "%.1f", empty: "--.-"),
                                  level: ble.tune?.advance == nil ? .off : .info,
                                  status: ble.tune?.advance == nil ? "" : "vor OT")
                        mapCard
                    }

                    HStack(spacing: 10) {
                        voltageCard
                        CompactCard(title: "Spule",
                                    text: format(ble.tune?.coilCurrent, "%.1f", empty: "-.-"),
                                    unit: "A",
                                    level: ble.tune?.coilCurrent == nil ? .off : .info)
                        CompactCard(title: "Modul",
                                    text: format(ble.tune?.moduleTemp, "%.0f", empty: "--"),
                                    unit: "°C",
                                    level: ble.tune?.moduleTemp.map { Limits.moduleTemp($0) } ?? .off)
                    }

                    // ── Verlauf ──
                    GraphCard(history: ble.history)

                    if !ble.anyLive {
                        Button(action: ble.toggleDemo) {
                            Text(ble.isDemo ? "Demo beenden" : "Demo-Werte zeigen")
                                .font(.system(size: 15, weight: .bold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .foregroundColor(ble.isDemo ? Theme.accent : Theme.fg)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(ble.isDemo ? Theme.accent : Theme.line, lineWidth: 1)
                                }
                        }
                        .padding(.top, 4)
                    }

                    Text("Verbindet sich automatisch mit „Citroen-Anzeige“ und der 123ignition, sobald sie Strom haben. Die 123 nimmt nur eine Verbindung an – die 123-App vorher schließen.")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        }
        .preferredColorScheme(.dark)
    }

    // ── Kopf mit zwei Verbindungsanzeigen ──
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CITROËN ANZEIGE")
                .font(.system(size: 13, weight: .heavy))
                .tracking(2)
                .foregroundColor(Theme.accent)
            HStack(spacing: 8) {
                StatusPill(label: "Anzeige", state: ble.bridgeState)
                StatusPill(label: "123", state: ble.tuneState)
                Spacer(minLength: 0)
            }
        }
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.accent).frame(height: 1)
        }
    }

    // ── Bridge-Werte ──
    private var pressureCard: some View {
        let p = ble.shown?.pressure
        let judged: (Level, String) = p.map { Limits.pressure($0) } ?? (.off, "")
        let text: String = p.map { $0 < 0 ? "---" : String(format: "%.2f", $0) } ?? "-.--"
        return ValueCard(title: "Öldruck", symbol: "drop.fill", unit: "bar",
                         text: text, level: judged.0, status: judged.1)
    }

    private var temperatureCard: some View {
        let t = ble.shown?.temp
        let judged: (Level, String) = t.map { Limits.temperature($0) } ?? (.off, "")
        let text: String = t.map { $0 < 0 ? "---" : String(format: "%.1f", $0) } ?? "--.-"
        return ValueCard(title: "Öltemp.", symbol: "thermometer", unit: "°C",
                         text: text, level: judged.0, status: judged.1)
    }

    // ── 123-Werte ──
    private var rpmStatus: String {
        switch ble.tuneState {
        case .live, .demo:
            return ble.tune?.rpm == nil ? "warte auf Daten …" : ""
        case .connecting:   return "verbinde …"
        case .searching:    return "suche 123ignition …"
        case .bluetoothOff: return "Bluetooth aus"
        case .unauthorized: return "kein Bluetooth-Zugriff"
        }
    }

    /// Saugrohrdruck: absolut in kPa, darunter relativ zur Atmosphaere
    private var mapCard: some View {
        let kPa = ble.tune?.mapKPa
        let status: String = kPa.map { String(format: "%+.2f bar", ($0 - 100) / 100) } ?? ""
        return ValueCard(title: "Saugrohr", symbol: "wind", unit: "kPa",
                         text: format(kPa, "%.0f", empty: "--"),
                         level: kPa == nil ? .off : .info,
                         status: status)
    }

    private var voltageCard: some View {
        let v = ble.tune?.voltage
        let judged: (Level, String) = v.map { Limits.voltage($0) } ?? (.off, "")
        return CompactCard(title: "Bordnetz",
                           text: format(v, "%.1f", empty: "--.-"),
                           unit: "V", level: judged.0, status: judged.1)
    }

    private func format(_ v: Double?, _ f: String, empty: String) -> String {
        guard let v else { return empty }
        return String(format: f, v)
    }
}

struct StatusPill: View {
    let label: String
    let state: LinkState

    private var look: (String, Color) {
        switch state {
        case .searching:    return ("Suche …", Theme.warn)
        case .connecting:   return ("Verbinde …", Theme.warn)
        case .live:         return ("Live", Theme.ok)
        case .demo:         return ("Demo", Theme.accent)
        case .bluetoothOff: return ("BT aus", Theme.muted)
        case .unauthorized: return ("Kein Zugriff", Theme.muted)
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(look.1).frame(width: 7, height: 7)
            Text(label.uppercased())
                .foregroundColor(Theme.fg)
            Text(look.0.uppercased())
        }
        .font(.system(size: 11, weight: .semibold))
        .tracking(0.8)
        .foregroundColor(look.1)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .overlay {
            Capsule().stroke(look.1.opacity(0.45), lineWidth: 1)
        }
    }
}

struct WarningBanner: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(Theme.fg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Theme.crit.opacity(0.22))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Theme.crit.opacity(0.55), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
