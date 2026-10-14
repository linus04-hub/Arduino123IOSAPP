import SwiftUI

// ── Tab "Einstellungen" ──────────────────────────────────────────
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var location: LocationManager
    @ObservedObject var recorder: TripRecorder

    @AppStorage(SettingKey.night) private var night: NightMode = .off
    @AppStorage(SettingKey.liveActivity) private var liveActivity = true
    @AppStorage(SettingKey.gps) private var gps = true
    @AppStorage(SettingKey.autoRecord) private var autoRecord = true
    @AppStorage("layout") private var layout: AppLayout = .standard

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Nachtmodus", selection: $night) {
                        ForEach(NightMode.allCases) { m in
                            Text(m.title).tag(m)
                        }
                    }
                    Picker("Ansicht im Live-Tab", selection: $layout) {
                        ForEach(AppLayout.allCases) { l in
                            Text(l.title).tag(l)
                        }
                    }
                } header: {
                    Text("Anzeige")
                } footer: {
                    Text("Der Nachtmodus dunkelt alles ab und färbt es warm, damit das Handy nachts nicht blendet.")
                }
                .listRowBackground(Theme.surface)

                Section {
                    Toggle("Live-Aktivität", isOn: $liveActivity)
                } footer: {
                    Text("Lambda, Öl, Drehzahl und Tempo auf dem Sperrbildschirm und in der Dynamic Island, solange Anzeige oder 123 verbunden sind.")
                }
                .listRowBackground(Theme.surface)

                Section {
                    Toggle("GPS für Tempo und Strecke", isOn: $gps)
                    if location.denied {
                        Text("Ortung ist für die App gesperrt. Einstellungen › Datenschutz › Ortungsdienste › Citroën › „Beim Verwenden“.")
                            .font(.system(size: 13))
                            .foregroundColor(Theme.warn)
                    }
                } footer: {
                    Text("Läuft auch bei gesperrtem Bildschirm weiter, solange die App aufzeichnet.")
                }
                .listRowBackground(Theme.surface)

                Section {
                    Toggle("Fahrten automatisch aufzeichnen", isOn: $autoRecord)
                } footer: {
                    Text("Startet, sobald der Motor 5 Sekunden läuft (Drehzahl von der 123 oder Öldruck), und endet eine Minute nach dem Abstellen.")
                }
                .listRowBackground(Theme.surface)

                Section {
                    LabeledContent("Version", value: version)
                    LabeledContent("Gespeicherte Fahrten", value: "\(recorder.trips.count)")
                } header: {
                    Text("Info")
                } footer: {
                    Text("Fahrten und Messreihen liegen in der Dateien-App unter „Auf meinem iPhone › Citroën“.")
                }
                .listRowBackground(Theme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .tint(Theme.accent)
            .navigationTitle("Einstellungen")
            .navBarStyle()
            .onChange(of: night) { _ in model.updateNight() }
            .onChange(of: gps) { on in model.setGPS(on) }
            .onChange(of: liveActivity) { _ in model.refreshLiveActivity() }
        }
    }
}
