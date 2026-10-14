import SwiftUI

// ── Tab "Live": die Anzeigen, unten die Leiste fuer Aufnahme und Markierungen ──
struct LiveView: View {
    @ObservedObject var ble: BLEManager
    let recorder: TripRecorder          // beobachtet die Leiste selbst
    let location: LocationManager
    @AppStorage("layout") private var layout: AppLayout = .standard

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
                    // In der Standard-Ansicht steht die 123-Warnung bei den Zuendungswerten
                    if layout != .standard, let w = ble.tuneWarning {
                        WarningBanner(text: w)
                    }

                    switch layout {
                    case .standard: StandardLayout(ble: ble)
                    case .dials:    DialsLayout(ble: ble)
                    case .focus:    FocusLayout(ble: ble)
                    case .tuning:   TuningLayout(ble: ble)
                    }

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
            .safeAreaInset(edge: .bottom, spacing: 0) {
                RecordBar(recorder: recorder, location: location)
            }
        }
    }

    // ── Kopf: Verbindungsanzeigen und Ansicht wechseln ──
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("CITROËN ANZEIGE")
                    .font(.system(size: 13, weight: .heavy))
                    .tracking(2)
                    .foregroundColor(Theme.accent)
                Spacer()
                Menu {
                    Picker("Ansicht", selection: $layout) {
                        ForEach(AppLayout.allCases) { l in
                            Label(l.title, systemImage: l.symbol).tag(l)
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: layout.symbol)
                        Text(layout.title)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.fg)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.surface2, in: Capsule())
                }
                .accessibilityLabel("Ansicht wechseln, aktuell \(layout.title)")
            }
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

// ── Leiste unten: Aufnahme, Tempo, Markierung ────────────────────
struct RecordBar: View {
    @ObservedObject var recorder: TripRecorder
    @ObservedObject var location: LocationManager
    @State private var toast: String?

    var body: some View {
        HStack(spacing: 10) {
            Button {
                if recorder.isRecording { recorder.stop() } else { recorder.start() }
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(recorder.isRecording ? Theme.crit : Theme.muted)
                        .frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(recorder.isRecording ? "AUFNAHME" : "AUFNAHME AUS")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(Theme.muted)
                        Text(recorder.isRecording ? Format.duration(recorder.current?.duration ?? 0) : "Start")
                            .font(.system(size: 16, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundColor(Theme.fg)
                    }
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 48)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(recorder.isRecording ? "Aufnahme beenden" : "Aufnahme starten")

            VStack(alignment: .leading, spacing: 0) {
                Text("TEMPO")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Theme.muted)
                Text(location.speedKmh.map { String(format: "%.0f km/h", $0) } ?? "-- km/h")
                    .font(.system(size: 16, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundColor(location.speedKmh == nil ? Theme.muted : Theme.fg)
                if let km = recorder.current?.distanceKm {
                    Text(String(format: "%.1f km", km))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundColor(Theme.muted)
                }
            }

            Spacer(minLength: 0)

            Button {
                let n = recorder.addMarker()
                show("Markierung \(n) gesetzt")
            } label: {
                Label("Markierung", systemImage: "flag.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Color.black)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 48)
                    .background(Theme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
        .overlay(alignment: .top) {
            if let t = toast {
                Text(t)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Color.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Theme.accent, in: Capsule())
                    .offset(y: -46)
                    .transition(.opacity)
            }
        }
    }

    private func show(_ text: String) {
        withAnimation(.easeOut(duration: 0.2)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(.easeIn(duration: 0.3)) { toast = nil }
        }
    }
}

// ── Formatierung fuer alle Seiten ────────────────────────────────
enum Format {
    static func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }

    static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "EEE, d. MMM yyyy"
        return f
    }()

    static let dayTimeFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "EEE, d. MMM · HH:mm"
        return f
    }()

    static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func day(_ d: Date) -> String { dayFormat.string(from: d) }
    static func dayTime(_ d: Date) -> String { dayTimeFormat.string(from: d) }
    static func time(_ d: Date) -> String { timeFormat.string(from: d) }

    /// Wert mit Einheit oder Gedankenstrich
    static func value(_ v: Double?, _ format: String, _ unit: String = "") -> String {
        guard let v else { return "–" }
        let s = String(format: format, v)
        return unit.isEmpty ? s : s + " " + unit
    }
}
