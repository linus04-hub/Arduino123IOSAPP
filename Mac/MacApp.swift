import SwiftUI
import AppKit

// ── Citroën Analyse: Auswertung am Mac ───────────────────────────
// Liest die Daten der iPhone-App (Fahrten, Messreihen, Logbuch, Tankbuch)
// und wertet sie auf dem grossen Bildschirm aus. Nur lesend: Aufgezeichnet
// und eingetragen wird auf dem iPhone.

enum Page: String, CaseIterable, Identifiable, Hashable {
    case overview, trips, overall, sessions, compare, pulls, tipIns, logbook, fuel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Übersicht"
        case .trips:    return "Fahrten"
        case .overall:  return "Gesamtauswertung"
        case .sessions: return "Messreihen"
        case .compare:  return "Vergleich"
        case .pulls:    return "Züge unter Last"
        case .tipIns:   return "Gasstöße"
        case .logbook:  return "Logbuch"
        case .fuel:     return "Tankbuch"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.bottom.50percent"
        case .trips:    return "car.side"
        case .overall:  return "square.grid.3x3.fill"
        case .sessions: return "tray.full"
        case .compare:  return "arrow.left.arrow.right"
        case .pulls:    return "gauge.with.dots.needle.67percent"
        case .tipIns:   return "waveform.path.ecg"
        case .logbook:  return "book.closed"
        case .fuel:     return "fuelpump"
        }
    }

    static let groups: [(String, [Page])] = [
        ("", [.overview]),
        ("Daten", [.trips, .sessions, .logbook, .fuel]),
        ("Auswertung", [.overall, .compare, .pulls, .tipIns])
    ]
}

/// Zeitraum zum Auswaehlen
enum PeriodChoice: String, CaseIterable, Identifiable, Hashable {
    case days7, days30, days90, sinceChange, all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .days7:       return "Letzte 7 Tage"
        case .days30:      return "Letzte 30 Tage"
        case .days90:      return "Letzte 90 Tage"
        case .sinceChange: return "Seit letzter Änderung"
        case .all:         return "Alles"
        }
    }

    func period(_ book: CarbBook, now: Date = Date()) -> Period {
        switch self {
        case .days7:  return .last(days: 7, now: now)
        case .days30: return .last(days: 30, now: now)
        case .days90: return .last(days: 90, now: now)
        case .all:    return .all
        case .sinceChange:
            let last = book.entries.map { $0.date }.max()
            return Period(from: last, to: nil)
        }
    }
}

/// Datenquelle fuer den Vergleich
enum SourceChoice: Hashable {
    case session(UUID)
    case before(UUID)
    case after(UUID)
    case period(PeriodChoice)
}

@MainActor
final class AppState: ObservableObject {
    @Published var page: Page? = .overview
    @Published var tripID: String?
    @Published var sessionID: UUID?
    @Published var logID: UUID?
    @Published var period: PeriodChoice = .sinceChange
    @Published var compareA: SourceChoice?
    @Published var compareB: SourceChoice?
    @Published var channels: [Channel] = AppState.loadChannels()
    @Published var pullSelection = Set<UUID>()
    // nur fuer die Bildschirmfotos
    @Published var snapshotHover: Double?
    @Published var snapshotSelection: ClosedRange<Double>?

    static func loadChannels() -> [Channel] {
        let raw = UserDefaults.standard.stringArray(forKey: "mac.channels") ?? []
        let list = raw.compactMap { Channel(rawValue: $0) }
        return list.isEmpty ? Channel.defaults : list
    }

    func toggle(_ c: Channel) {
        if let i = channels.firstIndex(of: c) {
            if channels.count > 1 { channels.remove(at: i) }
        } else {
            channels.append(c)
            channels.sort { Channel.allCases.firstIndex(of: $0)! < Channel.allCases.firstIndex(of: $1)! }
        }
        UserDefaults.standard.set(channels.map { $0.rawValue }, forKey: "mac.channels")
    }

    func open(trip id: String) {
        tripID = id
        page = .trips
    }
}

@main
struct CitroenAnalyseApp: App {
    @StateObject private var lib = Library()
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup("Citroën Analyse") {
            RootView()
                .environmentObject(lib)
                .environmentObject(app)
                .frame(minWidth: 1100, minHeight: 720)
                .task {
                    let demo = Snapshot.directory != nil || UserDefaults.standard.bool(forKey: "mac.demo")
                    lib.load(demo: demo)
                    if let dir = Snapshot.directory { await Snapshot.run(lib: lib, app: app, dir: dir) }
                }
        }
        .defaultSize(width: 1440, height: 920)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Importieren …") { Self.importPanel(lib) }
                    .keyboardShortcut("i")
                Button("Vom iPhone holen") { lib.syncFromPhone() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Neu laden") { lib.reload() }
                    .keyboardShortcut("r")
                Divider()
                Button("Datenordner im Finder zeigen") { lib.showInFinder() }
            }
            CommandMenu("Gehe zu") {
                ForEach(Array(Page.allCases.enumerated()), id: \.element) { i, p in
                    Button(p.title) { app.page = p }
                        .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
                }
            }
        }

        Settings {
            MacSettingsView()
                .environmentObject(lib)
        }
    }

    @MainActor
    static func importPanel(_ lib: Library) {
        let panel = NSOpenPanel()
        panel.title = "Daten importieren"
        panel.message = "Fahrten (.csv/.json), Messreihen, Vergaser.json, Tankbuch.json oder ganze Ordner"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { lib.importItems(panel.urls) }
    }
}

// ── Hauptfenster ─────────────────────────────────────────────────
struct RootView: View {
    @EnvironmentObject var lib: Library
    @EnvironmentObject var app: AppState

    var body: some View {
        NavigationSplitView {
            List(selection: $app.page) {
                ForEach(Page.groups, id: \.0) { group in
                    Section(group.0) {
                        ForEach(group.1) { p in
                            Label(p.title, systemImage: p.symbol)
                                .tag(p)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) { SidebarFooter() }
            .modifier(SnapshotOpaque())
        } detail: {
            Group {
                if !lib.loaded {
                    ProgressView("Lade Daten …")
                } else if !lib.hasData {
                    WelcomeView()
                } else {
                    switch app.page ?? .overview {
                    case .overview: OverviewView()
                    case .trips:    TripsPage()
                    case .overall:  OverallPage()
                    case .sessions: SessionsPage()
                    case .compare:  ComparePage()
                    case .pulls:    PullsPage()
                    case .tipIns:   TipInsPage()
                    case .logbook:  LogbookPage()
                    case .fuel:     FuelPage()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if lib.pending > 0 {
                    ProgressView()
                        .controlSize(.small)
                        .help("Werte \(lib.pending) Fahrten aus …")
                }
                Button {
                    lib.syncFromPhone()
                } label: {
                    Label("Vom iPhone holen", systemImage: "iphone.and.arrow.forward")
                }
                .help("Fahrten und Messreihen jetzt vom iPhone holen")
                .disabled(lib.demo || lib.sync == .running)
                Button {
                    CitroenAnalyseApp.importPanel(lib)
                } label: {
                    Label("Importieren", systemImage: "square.and.arrow.down")
                }
                .help("Dateien oder Ordner übernehmen")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            lib.importItems(urls)
            return true
        }
    }
}

struct SidebarFooter: View {
    @EnvironmentObject var lib: Library

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            if lib.demo {
                Label("Beispieldaten", systemImage: "theatermasks")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            switch lib.sync {
            case .running:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Hole Daten vom iPhone …").font(.caption)
                }
            case .done(let t):
                Text(t).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            case .failed(let t):
                Text(t).font(.caption).foregroundStyle(.red).lineLimit(3)
            case .idle:
                EmptyView()
            }
            if let d = lib.lastSync {
                Text("iPhone: " + Fmt.relative(d))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text("\(lib.trips.count) Fahrten · \(lib.sessions.count) Messreihen")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }
}

/// Ohne Daten: erklaeren, wie sie auf den Mac kommen
struct WelcomeView: View {
    @EnvironmentObject var lib: Library

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "car.side")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.orange)
            Text("Noch keine Daten")
                .font(.title.weight(.semibold))
            VStack(alignment: .leading, spacing: 10) {
                Label("Automatisch: Der Mac holt die Daten jede Stunde vom iPhone, wenn die Automatik eingerichtet ist. Sofort: Knopf „Vom iPhone holen“.", systemImage: "iphone.and.arrow.forward")
                Label("Von Hand: iPhone per Kabel anschließen, im Finder beim iPhone unter „Dateien“ den Ordner „Citroën“ hierher ziehen.", systemImage: "cable.connector")
                Label("Einzelne Dateien: Fahrten (.csv), Messreihen oder Vergaser.json per AirDrop schicken und hierher ziehen.", systemImage: "square.and.arrow.down")
            }
            .frame(maxWidth: 560, alignment: .leading)
            .foregroundStyle(.secondary)
            HStack {
                Button("Vom iPhone holen") { lib.syncFromPhone() }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                Button("Importieren …") { CitroenAnalyseApp.importPanel(lib) }
                Button("Beispieldaten ansehen") { lib.setDemo(true) }
            }
        }
        .padding(40)
    }
}
