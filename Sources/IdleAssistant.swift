import SwiftUI
import Combine
import Charts

// ── Leerlauf-Assistent: Gemischschraube Schritt fuer Schritt ─────
// Nach jedem Dreh an der Gemischschraube wartet die App 10 s, bis der
// Motor sich eingependelt hat, und mittelt dann 10 s lang Lambda und
// Drehzahl. Jede Stellung landet in einer Tabelle; markiert wird die
// Stellung mit der hoechsten Drehzahl bei ruhigem Lambda.

/// Mittelwert und Streuung eines Werts in einem Zeitfenster des Verlaufs
struct WindowStat {
    let mean: Double
    let spread: Double
    let count: Int
}

enum SampleWindow {
    static func stat(_ samples: [Sample], from: Date, to: Date, _ value: (Sample) -> Double?) -> WindowStat? {
        var vals: [Double] = []
        for s in samples where s.time >= from && s.time <= to {
            if let v = value(s) { vals.append(v) }
        }
        guard vals.count >= 4 else { return nil }
        let n = Double(vals.count)
        let m = vals.reduce(0, +) / n
        var sq = 0.0
        for v in vals { sq += (v - m) * (v - m) }
        return WindowStat(mean: m, spread: (sq / n).squareRoot(), count: vals.count)
    }
}

struct IdleStep: Codable, Identifiable, Hashable {
    var id = UUID()
    var turns: Double            // Umdrehungen ab Start, + = herausgedreht
    var lambda: Double?
    var rpm: Double?
    var lambdaSpread: Double?
    var rpmSpread: Double?
    var time = Date()
}

final class IdleAssistant: ObservableObject {
    @Published private(set) var steps: [IdleStep] = []
    @Published private(set) var position: Double = 0
    @Published private(set) var measureStart: Date?
    @Published private(set) var message: String?

    static let settle: TimeInterval = 10      // Einschwingen nach dem Drehen
    static let window: TimeInterval = 10      // Mittelungszeit
    private static let key = "idleAssistant"

    private struct Saved: Codable {
        var steps: [IdleStep]
        var position: Double
    }

    init() {
        load()
    }

    var isMeasuring: Bool { measureStart != nil }

    /// Fortschritt der laufenden Messung, 0 … 1
    func progress(now: Date) -> Double {
        guard let s = measureStart else { return 0 }
        return min(1, max(0, now.timeIntervalSince(s) / (Self.settle + Self.window)))
    }

    /// true, solange noch eingeschwungen wird (erste 10 s)
    func settling(now: Date) -> Bool {
        guard let s = measureStart else { return false }
        return now.timeIntervalSince(s) < Self.settle
    }

    /// Schraube wurde gedreht: Einschwingen abwarten, dann messen
    func turned(by delta: Double) {
        position += delta
        measureStart = Date()
        message = nil
        save()
    }

    /// Ohne Drehen: die letzten 10 s sofort als Stellung uebernehmen
    func measureNow(history: [Sample]) {
        let now = Date()
        record(history: history, from: now.addingTimeInterval(-Self.window), to: now)
    }

    /// Alle 0,5 s aus der Ansicht
    func tick(history: [Sample], now: Date) {
        guard let s = measureStart else { return }
        let end = s.addingTimeInterval(Self.settle + Self.window)
        guard now >= end else { return }
        measureStart = nil
        // Der Verlauf reicht nur 60 s zurueck
        if now.timeIntervalSince(end) > 40 {
            message = "Messung verworfen, die Ansicht war zu lange geschlossen. Bitte „Jetzt messen“ tippen."
            return
        }
        record(history: history, from: s.addingTimeInterval(Self.settle), to: end)
    }

    func cancel() {
        measureStart = nil
    }

    func delete(_ step: IdleStep) {
        steps.removeAll { $0.id == step.id }
        save()
    }

    func reset() {
        steps = []
        position = 0
        measureStart = nil
        message = nil
        save()
    }

    /// Stellung mit der hoechsten Drehzahl, bevorzugt bei ruhigem Lambda
    var best: IdleStep? {
        let withRPM = steps.filter { $0.rpm != nil }
        let calm = withRPM.filter { ($0.lambdaSpread ?? 1) < 0.03 }
        let pool = calm.isEmpty ? withRPM : calm
        return pool.max { ($0.rpm ?? 0) < ($1.rpm ?? 0) }
    }

    private func record(history: [Sample], from: Date, to: Date) {
        let l = SampleWindow.stat(history, from: from, to: to) { $0.lambda }
        let r = SampleWindow.stat(history, from: from, to: to) { $0.rpm }
        guard l != nil || r != nil else {
            message = "Keine Werte im Messfenster. Sind Anzeige und 123 verbunden?"
            return
        }
        steps.append(IdleStep(turns: position, lambda: l?.mean, rpm: r?.mean,
                              lambdaSpread: l?.spread, rpmSpread: r?.spread))
        message = nil
        save()
    }

    private func save() {
        guard let d = try? JSONEncoder().encode(Saved(steps: steps, position: position)) else { return }
        UserDefaults.standard.set(d, forKey: Self.key)
    }

    private func load() {
        guard let d = UserDefaults.standard.data(forKey: Self.key),
              let s = try? JSONDecoder().decode(Saved.self, from: d) else { return }
        steps = s.steps
        position = s.position
    }

    /// +¼, −½, +1⅛ …  (+ = herausgedreht)
    static func turnsText(_ t: Double) -> String {
        let eighths = Int((abs(t) * 8).rounded())
        if eighths == 0 { return "0" }
        let whole = eighths / 8
        let rest = eighths % 8
        let fractions = ["", "⅛", "¼", "⅜", "½", "⅝", "¾", "⅞"]
        let body = (whole > 0 ? "\(whole)" : "") + fractions[rest]
        return (t > 0 ? "+" : "−") + body
    }
}

// ── Ansicht ──────────────────────────────────────────────────────
struct IdleAssistantView: View {
    @ObservedObject var ble: BLEManager
    @ObservedObject var idle: IdleAssistant
    @AppStorage("idleStepSize") private var stepSize = 0.25
    @State private var confirmReset = false

    private let clock = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        let now = Date()
        let from = now.addingTimeInterval(-IdleAssistant.window)
        let lam = SampleWindow.stat(ble.history, from: from, to: now) { $0.lambda }
        let rpm = SampleWindow.stat(ble.history, from: from, to: now) { $0.rpm }
        ScrollView {
            VStack(spacing: 12) {
                liveCard(lam: lam, rpm: rpm)
                controls
                if !idle.steps.isEmpty {
                    chartCard
                    tableCard
                }
                howTo
            }
            .padding(16)
        }
        .background(Theme.bg)
        .navigationTitle("Leerlauf-Assistent")
        .navigationBarTitleDisplayMode(.inline)
        .navBarStyle()
        .onReceive(clock) { t in idle.tick(history: ble.history, now: t) }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Neu") { confirmReset = true }
                    .disabled(idle.steps.isEmpty && idle.position == 0)
            }
        }
        .confirmationDialog("Tabelle leeren und bei 0 neu anfangen?", isPresented: $confirmReset,
                            titleVisibility: .visible) {
            Button("Neu anfangen", role: .destructive) { idle.reset() }
            Button("Abbrechen", role: .cancel) {}
        }
    }

    // ── Live: Mittel der letzten 10 s ──
    private func liveCard(lam: WindowStat?, rpm: WindowStat?) -> some View {
        let lamLevel: Level = lam.map { Limits.lambda($0.mean).0 } ?? .off
        let calm = lam.map { calmText($0.spread) } ?? ""
        return Panel {
            VStack(alignment: .leading, spacing: 10) {
                CardLabel(title: "Mittel der letzten 10 s")
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("LAMBDA").font(.system(size: 10, weight: .bold)).foregroundColor(Theme.muted)
                        Text(lam.map { String(format: "%.3f", $0.mean) } ?? "-.---")
                            .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundColor(lamLevel.color)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("U/MIN").font(.system(size: 10, weight: .bold)).foregroundColor(Theme.muted)
                        Text(rpm.map { String(format: "%.0f", $0.mean) } ?? "----")
                            .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundColor(rpm == nil ? Theme.muted : Theme.fg)
                    }
                }
                HStack {
                    Text("Ruhe")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.muted)
                    Text(calm)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(calmColor(lam?.spread))
                    Spacer()
                    Text(spreadText(lam: lam, rpm: rpm))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundColor(Theme.muted)
                }
                if let hint = hint(rpm: rpm, lam: lam) {
                    Text(hint)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.warn)
                }
            }
        }
    }

    private func calmText(_ spread: Double) -> String {
        if spread < 0.015 { return "ruhig" }
        if spread < 0.03 { return "etwas unruhig" }
        return "unruhig"
    }

    private func calmColor(_ spread: Double?) -> Color {
        guard let s = spread else { return Theme.muted }
        if s < 0.015 { return Theme.ok }
        if s < 0.03 { return Theme.warn }
        return Theme.crit
    }

    private func spreadText(lam: WindowStat?, rpm: WindowStat?) -> String {
        var parts: [String] = []
        if let l = lam { parts.append(String(format: "λ ±%.3f", l.spread)) }
        if let r = rpm { parts.append(String(format: "±%.0f U/min", r.spread)) }
        return parts.joined(separator: " · ")
    }

    private func hint(rpm: WindowStat?, lam: WindowStat?) -> String? {
        if rpm == nil && lam == nil { return "Keine Werte. Anzeige und 123 müssen verbunden sein." }
        if rpm == nil { return "Keine Drehzahl. Ist die 123 verbunden?" }
        if let r = rpm, r.mean > 1400 { return "Drehzahl zu hoch für Leerlauf. Gas ganz loslassen." }
        if let t = ble.shown?.temp, t >= 0, t < 60 { return "Öl noch unter 60 °C. Für saubere Werte erst warm fahren." }
        return nil
    }

    // ── Bedienung ──
    private var controls: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardLabel(title: "Gemischschraube")
                    Spacer()
                    Text("Stellung \(IdleAssistant.turnsText(idle.position))")
                        .font(.system(size: 13, weight: .bold).monospacedDigit())
                        .foregroundColor(Theme.fg)
                }
                Picker("Schritt", selection: $stepSize) {
                    Text("⅛ Umdrehung").tag(0.125)
                    Text("¼ Umdrehung").tag(0.25)
                    Text("½ Umdrehung").tag(0.5)
                }
                .pickerStyle(.segmented)

                if idle.isMeasuring {
                    TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: idle.progress(now: ctx.date))
                                .tint(Theme.accent)
                            HStack {
                                Text(idle.settling(now: ctx.date) ? "Motor pendelt sich ein …" : "Messe 10 s …")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(Theme.fg)
                                Spacer()
                                Button("Abbrechen") { idle.cancel() }
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(Theme.accent)
                            }
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        stepButton(title: "\(fraction) rein gedreht", delta: -stepSize)
                        stepButton(title: "\(fraction) raus gedreht", delta: stepSize)
                    }
                    Button {
                        idle.measureNow(history: ble.history)
                    } label: {
                        Text(idle.steps.isEmpty ? "Ausgangsstellung jetzt messen" : "Stellung jetzt messen")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .foregroundColor(Theme.fg)
                            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                if let m = idle.message {
                    Text(m)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.warn)
                }
            }
        }
    }

    private var fraction: String {
        switch stepSize {
        case 0.125: return "⅛"
        case 0.5:   return "½"
        default:    return "¼"
        }
    }

    private func stepButton(title: String, delta: Double) -> some View {
        Button {
            idle.turned(by: delta)
        } label: {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundColor(Color.black)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // ── Diagramm: Drehzahl ueber Stellung, Lambda als Beschriftung ──
    private var chartCard: some View {
        let pts = idle.steps.filter { $0.rpm != nil }.sorted { $0.turns < $1.turns }
        return Panel {
            VStack(alignment: .leading, spacing: 8) {
                CardLabel(title: "Drehzahl je Stellung")
                if pts.count < 2 {
                    Text("Ab zwei Stellungen erscheint hier die Kurve.")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.muted)
                } else {
                    Chart {
                        ForEach(pts) { s in
                            LineMark(x: .value("Stellung", s.turns), y: .value("U/min", s.rpm ?? 0))
                                .foregroundStyle(Theme.accent)
                            PointMark(x: .value("Stellung", s.turns), y: .value("U/min", s.rpm ?? 0))
                                .foregroundStyle(s.id == idle.best?.id ? Theme.ok : Theme.accent)
                                .annotation(position: .top) {
                                    Text(s.lambda.map { String(format: "%.2f", $0) } ?? "")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundColor(Theme.muted)
                                }
                        }
                    }
                    .chartXAxisLabel("Umdrehungen (+ = raus)")
                    .chartYAxisLabel("U/min")
                    .chartYScale(domain: .automatic(includesZero: false))
                    .frame(height: 190)
                }
            }
        }
    }

    // ── Tabelle ──
    private var tableCard: some View {
        let best = idle.best
        return Panel {
            VStack(alignment: .leading, spacing: 6) {
                CardLabel(title: "Gemessene Stellungen")
                HStack {
                    Text("Stellung").frame(width: 64, alignment: .leading)
                    Text("Lambda").frame(maxWidth: .infinity, alignment: .trailing)
                    Text("U/min").frame(maxWidth: .infinity, alignment: .trailing)
                    Text("Ruhe λ").frame(maxWidth: .infinity, alignment: .trailing)
                }
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(Theme.muted)
                ForEach(idle.steps) { s in
                    row(s, isBest: s.id == best?.id)
                        .contextMenu {
                            Button(role: .destructive) {
                                idle.delete(s)
                            } label: {
                                Label("Zeile löschen", systemImage: "trash")
                            }
                        }
                }
                if let b = best, idle.steps.count >= 3 {
                    Text(recommendation(b))
                        .font(.system(size: 12))
                        .foregroundColor(Theme.fg)
                        .padding(.top, 4)
                }
                Text("Lange auf eine Zeile drücken, um sie zu löschen.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.muted)
            }
        }
    }

    private func row(_ s: IdleStep, isBest: Bool) -> some View {
        HStack {
            HStack(spacing: 4) {
                if isBest {
                    Image(systemName: "star.fill").font(.system(size: 9)).foregroundColor(Theme.ok)
                }
                Text(IdleAssistant.turnsText(s.turns))
            }
            .frame(width: 64, alignment: .leading)
            Text(s.lambda.map { String(format: "%.3f", $0) } ?? "–")
                .foregroundColor(s.lambda.map { Limits.lambda($0).0.color } ?? Theme.muted)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(s.rpm.map { String(format: "%.0f", $0) } ?? "–")
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(s.lambdaSpread.map { String(format: "±%.3f", $0) } ?? "–")
                .foregroundColor(calmColor(s.lambdaSpread))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 14, weight: isBest ? .bold : .regular).monospacedDigit())
        .foregroundColor(Theme.fg)
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .background(isBest ? Theme.ok.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func recommendation(_ b: IdleStep) -> String {
        let pos = IdleAssistant.turnsText(b.turns)
        let lam = b.lambda.map { String(format: "λ %.3f", $0) } ?? "ohne Lambda"
        let r = b.rpm.map { String(format: "%.0f U/min", $0) } ?? ""
        return "Höchste Drehzahl bei Stellung \(pos) (\(lam), \(r)). Üblich ist, von dort etwas magerer zu stellen, bis die Drehzahl um 20–30 U/min fällt. Danach die Leerlaufdrehzahl an der Anschlagschraube nachstellen und noch einmal messen."
    }

    // ── Kurzanleitung ──
    private var howTo: some View {
        Panel {
            VStack(alignment: .leading, spacing: 6) {
                CardLabel(title: "So geht's")
                Text("1. Motor warm fahren, Licht und Gebläse aus.\n2. „Ausgangsstellung jetzt messen“ tippen.\n3. Schraube um den gewählten Schritt drehen und sofort den passenden Knopf tippen. Die App wartet 10 s und misst dann 10 s.\n4. In beide Richtungen probieren, bis die Drehzahl auf beiden Seiten fällt.")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Bei den meisten Vergasern macht Reindrehen das Gemisch magerer. Die Tabelle zeigt es dir am gemessenen Lambda.")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
