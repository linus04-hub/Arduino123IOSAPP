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

                BridgeSection(ble: model.ble)

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

// ── Bridge (Joy-IT): Version und Update ohne Kabel ───────────────
struct BridgeSection: View {
    @ObservedObject var ble: BLEManager
    @State private var confirm = false
    @State private var started = false

    static let updatePage = URL(string: "http://192.168.4.1")!

    private var versionText: String {
        if let v = ble.bridgeVersion, ble.bridgeCanUpdate {
            return v.replacingOccurrences(of: "Bridge ", with: "v")
        }
        if ble.bridgeState == .live { return ble.bridgeCanUpdate ? "…" : "v2 oder älter" }
        return started ? "Update-Modus" : "nicht verbunden"
    }

    private var footer: String {
        if started {
            return "Am iPhone mit dem WLAN „Citroen-Update“ verbinden (Passwort 2cv-bridge), dann 192.168.4.1 öffnen und die .bin hochladen. Ohne Upload startet die Bridge nach 10 Minuten wieder normal."
        }
        if ble.bridgeState == .live && !ble.bridgeCanUpdate {
            return "Update ohne Kabel geht ab Bridge v3. Zeigt die App nach dem Flashen noch „v2 oder älter“: Bluetooth am iPhone einmal aus- und wieder einschalten."
        }
        return "Neue Bridge-Versionen kommen per WLAN auf den Joy-IT, ohne Ausbauen. Die .bin exportierst du in der Arduino IDE."
    }

    var body: some View {
        Section {
            LabeledContent("Version", value: versionText)
            if ble.bridgeCanUpdate {
                Button("Bridge aktualisieren") { confirm = true }
                    .confirmationDialog("Bridge in den Update-Modus schalten?", isPresented: $confirm,
                                        titleVisibility: .visible) {
                        Button("Update-Modus starten") { started = ble.startBridgeUpdate() }
                        Button("Abbrechen", role: .cancel) {}
                    } message: {
                        Text("Die Bridge startet neu und öffnet das WLAN „Citroen-Update“. Lambda und Öl sind so lange nicht zu sehen.")
                    }
            }
            if started {
                Link("192.168.4.1 in Safari öffnen", destination: Self.updatePage)
            }
        } header: {
            Text("Bridge (Joy-IT)")
        } footer: {
            Text(footer)
        }
        .listRowBackground(Theme.surface)
        .onChange(of: ble.bridgeState) { s in
            if s == .live { started = false }   // nach dem Update wieder da
        }
    }
}
