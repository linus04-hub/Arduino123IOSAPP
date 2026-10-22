import SwiftUI

// ── Gasstoss-Analyse: wie reagiert Lambda beim Gasgeben? ─────────
// Ohne Drosselklappen-Sensor wird ein Gasstoss so erkannt: Lambda war
// vorher ruhig, schlaegt dann schnell um mindestens 0,05 aus, und die
// Drehzahl steigt in den folgenden 3 s um mindestens 120 U/min. Faellt
// die Drehzahl dagegen (Schiebebetrieb), wird der Ausschlag verworfen.
// Ausgewertet wird der 4-Hz-Verlauf; sehr kurze Spitzen koennen fehlen.

struct TipInEvent: Codable, Identifiable, Hashable {
    var id = UUID()
    var time: Date
    var baseLambda: Double       // Mittel vor dem Gasstoss
    var peakLambda: Double       // magerster Wert danach
    var minLambda: Double        // fettester Wert danach
    var leanSeconds: Double      // Zeit ueber Basis + 0,03
    var rpmBefore: Double
    var rpmAfter: Double
    var trace: [Float]           // Lambda alle 0,25 s, ab 1 s vor dem Ausschlag

    var leanSpike: Double { peakLambda - baseLambda }
    var richDip: Double { baseLambda - minLambda }

    enum Verdict { case lean, rich, ok }

    var verdict: Verdict {
        if leanSpike >= 0.08 { return .lean }
        if richDip >= 0.10 && leanSpike < 0.04 { return .rich }
        return .ok
    }
}

final class TipInAnalyzer: ObservableObject {
    @Published private(set) var events: [TipInEvent] = []    // neueste zuerst

    static let maxEvents = 100
    static let triggerDelta = 0.05
    static let minRPMRise = 120.0

    private var buffer: [Sample] = []
    private var triggerAt: Date?
    private var base = 0.0
    private var rpmBefore = 0.0
    private var cooldownUntil = Date.distantPast

    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Gasstoesse.json")
    }

    init() {
        load()
    }

    /// Alle 0,25 s aus dem AppModel (Demo-Werte kommen hier nicht an)
    func add(_ s: Sample) {
        buffer.append(s)
        let cut = s.time.addingTimeInterval(-8)
        if let i = buffer.firstIndex(where: { $0.time >= cut }), i > 0 {
            buffer.removeFirst(i)
        }

        if let t = triggerAt {
            if s.time.timeIntervalSince(t) >= 3 {
                finish(at: t)
                triggerAt = nil
                cooldownUntil = s.time.addingTimeInterval(2)
            }
            return
        }

        guard s.time >= cooldownUntil, let l = s.lambda, let rpm = s.rpm, rpm >= 900 else { return }
        let from = s.time.addingTimeInterval(-2.0)
        let to = s.time.addingTimeInterval(-0.5)
        guard let b = SampleWindow.stat(buffer, from: from, to: to, { $0.lambda }),
              b.count >= 5, b.spread < 0.02,
              let r = SampleWindow.stat(buffer, from: from, to: to, { $0.rpm }) else { return }
        if abs(l - b.mean) >= Self.triggerDelta {
            triggerAt = s.time
            base = b.mean
            rpmBefore = r.mean
        }
    }

    func clear() {
        events = []
        save()
    }

    private func finish(at t: Date) {
        let end = t.addingTimeInterval(3)
        let after = buffer.filter { $0.time >= t && $0.time <= end }
        let rpms = after.filter { $0.time >= t.addingTimeInterval(0.75) }.compactMap { $0.rpm }
        // Nur echte Gasstoesse: Drehzahl muss danach steigen
        guard let rpmAfter = rpms.max(), rpmAfter - rpmBefore >= Self.minRPMRise else { return }
        let lams = after.compactMap { $0.lambda }
        guard let peak = lams.max(), let low = lams.min() else { return }

        var leanCount = 0
        for x in after {
            if let v = x.lambda, v > base + 0.03 { leanCount += 1 }
        }
        let b = base
        let trace: [Float] = buffer
            .filter { $0.time >= t.addingTimeInterval(-1) && $0.time <= end }
            .map { Float($0.lambda ?? b) }

        let e = TipInEvent(time: t, baseLambda: b, peakLambda: max(peak, b), minLambda: min(low, b),
                           leanSeconds: Double(leanCount) * BLEManager.graphStep,
                           rpmBefore: rpmBefore, rpmAfter: rpmAfter, trace: trace)
        events.insert(e, at: 0)
        if events.count > Self.maxEvents { events.removeLast(events.count - Self.maxEvents) }
        save()
    }

    // ── Zusammenfassung ──
    struct Summary {
        let count: Int
        let avgLeanSpike: Double
        let lean: Int
        let rich: Int
        let ok: Int
    }

    var summary: Summary? {
        guard !events.isEmpty else { return nil }
        var lean = 0
        var rich = 0
        var ok = 0
        var spikes = 0.0
        for e in events {
            spikes += e.leanSpike
            switch e.verdict {
            case .lean: lean += 1
            case .rich: rich += 1
            case .ok:   ok += 1
            }
        }
        return Summary(count: events.count, avgLeanSpike: spikes / Double(events.count),
                       lean: lean, rich: rich, ok: ok)
    }

    private func save() {
        guard let d = try? JSONEncoder().encode(events) else { return }
        try? d.write(to: Self.url, options: .atomic)
    }

    private func load() {
        guard let d = try? Data(contentsOf: Self.url),
              let e = try? JSONDecoder().decode([TipInEvent].self, from: d) else { return }
        events = e
    }
}

// ── Ansicht ──────────────────────────────────────────────────────
struct TipInView: View {
    @ObservedObject var analyzer: TipInAnalyzer
    @State private var confirmClear = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                summaryCard
                ForEach(analyzer.events.prefix(40)) { e in
                    TipInRow(event: e)
                }
                infoCard
            }
            .padding(16)
        }
        .background(Theme.bg)
        .navigationTitle("Gasstöße")
        .navigationBarTitleDisplayMode(.inline)
        .navBarStyle()
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Leeren") { confirmClear = true }
                    .disabled(analyzer.events.isEmpty)
            }
        }
        .confirmationDialog("Alle erkannten Gasstöße löschen?", isPresented: $confirmClear,
                            titleVisibility: .visible) {
            Button("Löschen", role: .destructive) { analyzer.clear() }
            Button("Abbrechen", role: .cancel) {}
        }
    }

    private var summaryCard: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                CardLabel(title: "Beschleunigerpumpe", symbol: "waveform.path.ecg")
                if let s = analyzer.summary {
                    HStack(spacing: 8) {
                        chip("\(s.lean) mager", Theme.crit)
                        chip("\(s.ok) sauber", Theme.ok)
                        chip("\(s.rich) fett", Theme.load)
                        Spacer()
                        Text(String(format: "Ø +%.3f", s.avgLeanSpike))
                            .font(.system(size: 13, weight: .bold).monospacedDigit())
                            .foregroundColor(Theme.fg)
                    }
                    Text(verdictText(s))
                        .font(.system(size: 13))
                        .foregroundColor(Theme.fg)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Noch keine Gasstöße erkannt. Fahr im zweiten oder dritten Gang mit etwa 1500–2500 U/min und gib ein paar Mal zügig Gas.")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule())
    }

    private func verdictText(_ s: TipInAnalyzer.Summary) -> String {
        let n = Double(s.count)
        if s.count < 5 {
            return "Erst \(s.count) Gasstöße erkannt. Ab etwa fünf ist das Bild belastbar."
        }
        if Double(s.lean) / n >= 0.5 {
            return "Beim Gasgeben wird das Gemisch meist kurz mager. Das deutet oft auf zu wenig Pumpenhub, eine harte oder rissige Pumpenmembran oder ein klemmendes Ventil der Beschleunigerpumpe hin."
        }
        if Double(s.rich) / n >= 0.5 {
            return "Beim Gasgeben wird das Gemisch meist deutlich fett. Die Beschleunigerpumpe gibt eher zu viel."
        }
        return "Unauffällig: Lambda bleibt beim Gasgeben meist im Rahmen."
    }

    private var infoCard: some View {
        Panel {
            Text("Erkannt wird ein Gasstoß, wenn Lambda nach ruhiger Fahrt schnell um mindestens 0,05 ausschlägt und die Drehzahl danach steigt. Ohne Drosselklappen-Sensor ist das eine Schätzung, einzelne Fehlerkennungen sind möglich. Lambda wird 4-mal pro Sekunde ausgewertet, sehr kurze Spitzen können fehlen. Demo-Werte werden nicht erfasst.")
                .font(.system(size: 11))
                .foregroundColor(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct TipInRow: View {
    let event: TipInEvent

    private var verdictLook: (String, Color) {
        switch event.verdict {
        case .lean: return ("mager", Theme.crit)
        case .rich: return ("fett", Theme.load)
        case .ok:   return ("sauber", Theme.ok)
        }
    }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(Format.dayTime(event.time))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.fg)
                    Spacer()
                    Text(verdictLook.0)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(verdictLook.1)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(verdictLook.1.opacity(0.15), in: Capsule())
                }
                TipInSparkline(event: event)
                    .frame(height: 70)
                Text(String(format: "λ %.3f → mager %.3f (+%.3f), fett %.3f · %.2f s mager · %.0f → %.0f U/min",
                            event.baseLambda, event.peakLambda, event.leanSpike, event.minLambda,
                            event.leanSeconds, event.rpmBefore, event.rpmAfter))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Lambda-Verlauf um den Gasstoss: gestrichelt die Basis, Strich beim Ausschlag
struct TipInSparkline: View {
    let event: TipInEvent

    var body: some View {
        Canvas { ctx, size in
            draw(ctx, size)
        }
        .accessibilityLabel("Lambda-Verlauf beim Gasstoß")
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let pts = event.trace.map { Double($0) }
        guard pts.count >= 2 else { return }
        let lo = min(pts.min() ?? event.baseLambda, event.baseLambda - 0.08)
        let hi = max(pts.max() ?? event.baseLambda, event.baseLambda + 0.12)
        let w = size.width
        let h = size.height
        func x(_ i: Int) -> CGFloat { CGFloat(i) / CGFloat(pts.count - 1) * w }
        func y(_ v: Double) -> CGFloat { CGFloat((hi - v) / (hi - lo)) * h }

        var baseLine = Path()
        baseLine.move(to: CGPoint(x: 0, y: y(event.baseLambda)))
        baseLine.addLine(to: CGPoint(x: w, y: y(event.baseLambda)))
        ctx.stroke(baseLine, with: .color(Theme.muted), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

        // Zeitpunkt des Ausschlags: 1 s nach Beginn des Ausschnitts
        let triggerIndex = min(pts.count - 1, Int((1.0 / BLEManager.graphStep).rounded()))
        var mark = Path()
        mark.move(to: CGPoint(x: x(triggerIndex), y: 0))
        mark.addLine(to: CGPoint(x: x(triggerIndex), y: h))
        ctx.stroke(mark, with: .color(Theme.line), lineWidth: 1)

        var line = Path()
        for (i, v) in pts.enumerated() {
            let p = CGPoint(x: x(i), y: y(v))
            if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
        }
        ctx.stroke(line, with: .color(Theme.accent),
                   style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

        ctx.draw(Text("mager").font(.system(size: 9)).foregroundColor(Theme.muted),
                 at: CGPoint(x: w - 2, y: 2), anchor: .topTrailing)
        ctx.draw(Text("fett").font(.system(size: 9)).foregroundColor(Theme.muted),
                 at: CGPoint(x: w - 2, y: h - 2), anchor: .bottomTrailing)
    }
}
