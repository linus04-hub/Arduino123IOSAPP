import SwiftUI

@main
struct CitroenAnzeigeApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
        .onChange(of: phase) { p in
            if p == .background { model.saveAll() }
            if p == .active { model.updateNight() }
        }
    }
}

// ── Vier Tabs: Live, Fahrten, Abstimmung, Einstellungen ──────────
struct RootView: View {
    @ObservedObject var model: AppModel
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            LiveView(ble: model.ble, recorder: model.recorder, location: model.location)
                .tabBarStyle()
                .tabItem { Label("Live", systemImage: "speedometer") }
                .tag(0)
            TripsView(recorder: model.recorder, tuning: model.tuning)
                .tabBarStyle()
                .tabItem { Label("Fahrten", systemImage: "car.fill") }
                .tag(1)
            TuningView(tuning: model.tuning, ble: model.ble, idle: model.idle, tipIns: model.tipIns)
                .tabBarStyle()
                .tabItem { Label("Abstimmung", systemImage: "chart.xyaxis.line") }
                .tag(2)
            SettingsView(model: model, location: model.location, recorder: model.recorder)
                .tabBarStyle()
                .tabItem { Label("Einstellungen", systemImage: "gearshape.fill") }
                .tag(3)
        }
        .tint(Theme.accent)
        .id(model.isNight)            // Nachtmodus: alles mit den neuen Farben neu aufbauen
        .preferredColorScheme(.dark)
    }
}

extension View {
    /// Dunkle Tab-Leiste in den Farben der App
    func tabBarStyle() -> some View {
        self
            .toolbarBackground(Theme.surface, for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
    }

    /// Dunkle Navigationsleiste in den Farben der App
    func navBarStyle() -> some View {
        self
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
    }
}
