import SwiftUI

// ── Gasstoss-Analyse: Ablage und Ansicht ─────────────────────────
// Die Erkennung selbst steht in TipInDetector.swift.

final class TipInAnalyzer: ObservableObject {
    @Published private(set) var events: [TipInEvent] = []    // neueste zuerst

    static let maxEvents = 100

    private var detector = TipInDetector()

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
        guard let e = detector.add(s) else { return }
        events.insert(e, at: 0)
        if events.count > Self.maxEvents { events.removeLast(events.count - Self.maxEvents) }
        save()
    }

    func clear() {
        events = []
        save()
    }

    var summary: TipInSummary? { events.summary }

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

    private func verdictText(_ s: TipInSummary) -> String {
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
