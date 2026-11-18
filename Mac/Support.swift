import SwiftUI
import AppKit

// ── Einstellungen ────────────────────────────────────────────────

struct MacSettingsView: View {
    @EnvironmentObject var lib: Library
    @AppStorage(MixtureTargets.key(.idle)) private var idle = MixtureTargets.defaults.idle
    @AppStorage(MixtureTargets.key(.stage1)) private var stage1 = MixtureTargets.defaults.stage1
    @AppStorage(MixtureTargets.key(.transition)) private var transition = MixtureTargets.defaults.transition
    @AppStorage(MixtureTargets.key(.stage2)) private var stage2 = MixtureTargets.defaults.stage2
    @AppStorage("idleTargetRPM") private var idleRPM = 850.0
    @AppStorage(Vehicle.massKey) private var mass = 700.0
    @AppStorage("mac.demo") private var demo = false
    @State private var folders: [String] = UserDefaults.standard.stringArray(forKey: DataPaths.extraKey) ?? []

    var body: some View {
        TabView {
            Form {
                Section("Ziel-Lambda") {
                    target("Leerlauf", $idle)
                    target("Teillast", $stage1)
                    target("Übergang zur 2. Stufe", $transition)
                    target("Vollgas", $stage2)
                    Button("Auf Standard zurücksetzen") {
                        let d = MixtureTargets.defaults
                        idle = d.idle
                        stage1 = d.stage1
                        transition = d.transition
                        stage2 = d.stage2
                    }
                }
                Section("Motor und Fahrzeug") {
                    Stepper(value: $idleRPM, in: 700...1200, step: 50) {
                        LabeledContent("Leerlaufdrehzahl soll", value: String(format: "%.0f U/min", idleRPM))
                    }
                    Stepper(value: $mass, in: 500...1100, step: 10) {
                        LabeledContent("Masse mit Fahrer", value: String(format: "%.0f kg", mass))
                    }
                }
                Text("Gleiche Bedeutung wie in der iPhone-App, aber getrennt eingestellt.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("Auswertung", systemImage: "stethoscope") }

            Form {
                Section("Woher die Daten kommen") {
                    LabeledContent("Vom iPhone", value: DataPaths.phone.path)
                    LabeledContent("Importiert", value: DataPaths.imported.path)
                    Button("Im Finder zeigen") { lib.showInFinder() }
                }
                Section("Weitere Ordner") {
                    ForEach(folders, id: \.self) { f in
                        HStack {
                            Text(f).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button(role: .destructive) {
                                folders.removeAll { $0 == f }
                                save()
                            } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                        }
                    }
                    Button("Ordner hinzufügen …") {
                        let p = NSOpenPanel()
                        p.canChooseDirectories = true
                        p.canChooseFiles = false
                        p.allowsMultipleSelection = true
                        if p.runModal() == .OK {
                            folders += p.urls.map { $0.path }.filter { !folders.contains($0) }
                            save()
                        }
                    }
                }
                Section {
                    Toggle("Beispieldaten statt eigener Daten zeigen", isOn: $demo)
                        .onChange(of: demo) { _, on in lib.setDemo(on) }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Daten", systemImage: "folder") }
        }
        .frame(width: 560, height: 430)
    }

    private func target(_ title: String, _ v: Binding<Double>) -> some View {
        Stepper(value: v, in: MixtureTargets.range, step: 0.01) {
            LabeledContent(title, value: String(format: "%.2f", v.wrappedValue))
        }
    }

    private func save() {
        UserDefaults.standard.set(folders, forKey: DataPaths.extraKey)
        lib.reload()
    }
}

// ── Bildschirmfotos ohne Bedienung ───────────────────────────────
// Startparameter "-snapshot <Ordner>": Beispieldaten laden, alle Seiten
// nacheinander zeigen, jede als PNG ablegen, beenden. Fuer den Workflow
// auf GitHub, damit sich die Oberflaeche ohne Mac pruefen laesst.

enum Snapshot {
    static var directory: URL? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "-snapshot"), i + 1 < a.count else { return nil }
        return URL(fileURLWithPath: a[i + 1], isDirectory: true)
    }

    @MainActor
    static func run(lib: Library, app: AppState, dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var log = "Start " + Date().description + "\n"
        func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

        for _ in 0..<480 {
            if lib.loaded && lib.pending == 0 && !lib.trips.isEmpty { break }
            await wait(0.25)
        }
        log += "Daten: \(lib.trips.count) Fahrten, \(lib.stats.count) ausgewertet\n"
        if let w = NSApp.windows.first(where: { $0.isVisible }) {
            w.setFrame(NSRect(x: 0, y: 0, width: 1500, height: 980), display: true)
        }
        // Fahrt mit den meisten Zuegen und einer Markierung zeigen
        let best = lib.trips.max { a, b in
            let pa = (lib.stats[a.id]?.pulls.count ?? 0) * 2 + a.summary.markers.count
            let pb = (lib.stats[b.id]?.pulls.count ?? 0) * 2 + b.summary.markers.count
            return pa < pb
        }
        let jet = lib.book.entries.first { $0.changes.contains { $0.contains("Hauptdüse Stufe 2") } }

        let steps: [(String, () -> Void)] = [
            ("01-uebersicht", { app.page = .overview }),
            ("02-fahrt", { app.tripID = best?.id; app.page = .trips }),
            ("03-gesamt", { app.period = .all; app.page = .overall }),
            ("04-gesamt-seit", { app.period = .sinceChange; app.page = .overall }),
            ("05-messreihen", { app.sessionID = lib.sessions.first?.id; app.page = .sessions }),
            ("06-vergleich", { app.page = .compare }),
            ("07-zuege", { app.pullSelection = []; app.page = .pulls }),
            ("08-gasstoesse", { app.page = .tipIns }),
            ("09-logbuch", { app.logID = jet?.id; app.page = .logbook }),
            ("10-tankbuch", { app.page = .fuel })
        ]
        for (name, action) in steps {
            action()
            await wait(name == "02-fahrt" || name.hasPrefix("03") || name.hasPrefix("09") ? 6 : 3.5)
            if name == "02-fahrt" {
                app.snapshotHover = 600
                app.snapshotSelection = 540...780
                await wait(1.5)
            }
            log += capturePages(name, dir: dir)
        }
        try? log.write(to: dir.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    /// Fenster ablichten, bei langen Seiten mehrmals nach unten gescrollt
    @MainActor
    static func capturePages(_ name: String, dir: URL) -> String {
        guard let w = NSApp.windows.first(where: { $0.isVisible }), let view = w.contentView else { return name + ": kein Fenster\n" }
        var out = ""
        let scroll = largestScrollView(in: view)
        var offset: CGFloat = 0
        for part in 0..<4 {
            if let s = scroll, let doc = s.documentView {
                let visible = s.contentView.bounds.height
                let maxOffset = max(0, doc.frame.height - visible)
                if part > 0 && offset >= maxOffset { break }
                let y = doc.isFlipped ? offset : maxOffset - offset
                s.contentView.scroll(to: NSPoint(x: 0, y: min(maxOffset, max(0, y))))
                s.reflectScrolledClipView(s.contentView)
                offset += visible * 0.85
            } else if part > 0 {
                break
            }
            view.layoutSubtreeIfNeeded()
            view.display()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let file = part == 0 ? name + ".png" : name + "-\(part + 1).png"
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: dir.appendingPathComponent(file))
                out += file + "\n"
            }
        }
        if let s = scroll, let doc = s.documentView {
            s.contentView.scroll(to: NSPoint(x: 0, y: doc.isFlipped ? 0 : max(0, doc.frame.height - s.contentView.bounds.height)))
        }
        return out
    }

    @MainActor
    static func largestScrollView(in view: NSView) -> NSScrollView? {
        var best: NSScrollView?
        var bestArea: CGFloat = 0
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView, s.documentView != nil {
                // die Seitenleiste ist schmal, die Seite selbst breit und hoch
                let area = s.frame.width * s.frame.height
                if s.frame.width > 500 && area > bestArea {
                    best = s
                    bestArea = area
                }
            }
            for c in v.subviews { walk(c) }
        }
        walk(view)
        return best
    }
}
