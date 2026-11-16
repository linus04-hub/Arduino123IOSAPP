import SwiftUI

// ── Beduesung und Logbuch ────────────────────────────────────────
// Oben der Stand im Vergaser, unten das Logbuch. "Eintragen" haelt eine
// Aenderung fest und sichert auf Wunsch die bisherige Messreihe, damit
// sich vorher und nachher vergleichen lassen.

struct CarbLogView: View {
    @ObservedObject var carb: CarbLog
    @ObservedObject var tuning: TuningStore

    @State private var draft = CarbSetup()
    @State private var note = ""
    @State private var archive = true
    @State private var loaded = false
    @State private var savedHint: String?
    @State private var toDelete: LogEntry?

    private var changes: [String] { CarbSetup.changes(from: carb.setup, to: draft) }
    private var canCommit: Bool {
        !changes.isEmpty || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            ForEach(0..<CarbSetup.Field.groupTitles.count, id: \.self) { g in
                Section {
                    ForEach(CarbSetup.Field.allCases.filter { $0.group == g }) { f in
                        fieldRow(f)
                    }
                } header: {
                    Text(CarbSetup.Field.groupTitles[g])
                } footer: {
                    if g == 0 {
                        Text("Düsen so eintragen, wie sie auf der Düse stehen (Durchmesser in 1/100 mm). Leer lassen, was du nicht weißt.")
                    }
                }
                .listRowBackground(Theme.surface)
            }

            Section {
                TextField("Notiz, z. B. Schwimmerstand korrigiert", text: $note, axis: .vertical)
                    .lineLimit(1...4)
                if !changes.isEmpty {
                    ForEach(changes, id: \.self) { c in
                        Label(c, systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 13))
                            .foregroundColor(Theme.accent)
                    }
                }
                Toggle("Messreihe sichern und neu beginnen", isOn: $archive)
                Button {
                    commit()
                } label: {
                    Text("Eintragen")
                        .font(.system(size: 16, weight: .bold))
                        .frame(maxWidth: .infinity)
                }
                .disabled(!canCommit)
                if let h = savedHint {
                    Text(h)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.ok)
                }
            } header: {
                Text("Änderung eintragen")
            } footer: {
                Text("Mit „sichern und neu beginnen“ wird die bisherige Messreihe unter dem Datum gespeichert und das Kennfeld geleert. Nach der nächsten Fahrt siehst du unter „Vergleich“, was die Änderung gebracht hat.")
            }
            .listRowBackground(Theme.surface)

            Section {
                if carb.book.entries.isEmpty {
                    Text("Noch keine Einträge.")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.muted)
                }
                ForEach(carb.book.entries) { e in
                    entryRow(e)
                }
                .onDelete { offsets in
                    if let i = offsets.first { toDelete = carb.book.entries[i] }
                }
            } header: {
                Text("Logbuch")
            } footer: {
                Text("Liegt als „Vergaser.json“ in der Dateien-App unter „Auf meinem iPhone › Citroën“.")
            }
            .listRowBackground(Theme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .tint(Theme.accent)
        .navigationTitle("Bedüsung und Logbuch")
        .navigationBarTitleDisplayMode(.inline)
        .navBarStyle()
        .onAppear {
            guard !loaded else { return }
            loaded = true
            carb.syncFromDefaults()
            draft = carb.setup
        }
        .confirmationDialog("Eintrag löschen?", isPresented: Binding(
            get: { toDelete != nil },
            set: { if !$0 { toDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                if let e = toDelete { carb.delete(e) }
                toDelete = nil
            }
        } message: {
            Text("Die Bedüsung selbst bleibt, wie sie ist.")
        }
    }

    private func fieldRow(_ f: CarbSetup.Field) -> some View {
        let value = Binding<Double?>(
            get: { draft[f] },
            set: { draft[f] = $0 }
        )
        return LabeledContent {
            HStack(spacing: 4) {
                TextField(f.hint, value: value, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 90)
                    .foregroundColor(draft[f] != carb.setup[f] ? Theme.accent : Theme.fg)
                if !f.unit.isEmpty {
                    Text(f.unit)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.muted)
                }
            }
        } label: {
            Text(f.title)
        }
    }

    private func entryRow(_ e: LogEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Format.dayTime(e.date))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundColor(Theme.muted)
            ForEach(e.changes, id: \.self) { c in
                Text(c)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.fg)
            }
            if !e.note.isEmpty {
                Text(e.note)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.fg)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let n = e.sessionName {
                Label("Messreihe davor: " + n, systemImage: "chart.xyaxis.line")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.muted)
            }
        }
        .padding(.vertical, 2)
    }

    private func commit() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        var saved: TuningSession?
        if archive {
            let name = "bis " + Format.dayTime(Date())
            saved = tuning.archiveCurrent(as: name)
        }
        guard carb.commit(draft, note: note, session: saved) != nil else { return }
        note = ""
        draft = carb.setup
        if archive {
            savedHint = saved == nil ? "Eingetragen. Die Messreihe war noch fast leer und wurde nur geleert."
                                     : "Eingetragen. Bisherige Messreihe gesichert, das Kennfeld beginnt neu."
        } else {
            savedHint = "Eingetragen."
        }
    }
}

// ── Tankbuch ─────────────────────────────────────────────────────
struct FuelView: View {
    @ObservedObject var fuel: FuelStore
    @ObservedObject var recorder: TripRecorder

    @State private var liters: Double?
    @State private var odometer: Double?
    @State private var price: Double?
    @State private var full = true
    @State private var date = Date()

    var body: some View {
        let results = fuel.results(trips: recorder.trips)
        Form {
            Section {
                LabeledContent("Durchschnitt") {
                    Text(FuelMath.average(Array(results.values)).map { String(format: "%.1f l/100 km", $0) } ?? "–")
                        .font(.system(size: 17, weight: .bold).monospacedDigit())
                        .foregroundColor(Theme.fg)
                }
            } footer: {
                Text("Gerechnet von Volltanken zu Volltanken. Mit Kilometerstand genau, sonst aus den GPS-Kilometern der aufgezeichneten Fahrten dazwischen. Ein hoher Verbrauch passt zu fettem Gemisch in der Teillast.")
            }
            .listRowBackground(Theme.surface)

            Section {
                numberRow("Getankt", "Liter", $liters)
                numberRow("Kilometerstand", "optional", $odometer)
                numberRow("Betrag", "Euro, optional", $price)
                Toggle("Vollgetankt", isOn: $full)
                DatePicker("Datum", selection: $date, in: ...Date())
                Button {
                    add()
                } label: {
                    Text("Tanken eintragen")
                        .font(.system(size: 16, weight: .bold))
                        .frame(maxWidth: .infinity)
                }
                .disabled((liters ?? 0) <= 0)
            } header: {
                Text("Neu")
            }
            .listRowBackground(Theme.surface)

            Section {
                if fuel.entries.isEmpty {
                    Text("Noch keine Einträge.")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.muted)
                }
                ForEach(fuel.entries) { e in
                    row(e, results[e.id])
                }
                .onDelete { offsets in
                    let doomed = offsets.map { fuel.entries[$0] }
                    for e in doomed { fuel.delete(e) }
                }
            } header: {
                Text("Einträge")
            }
            .listRowBackground(Theme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .tint(Theme.accent)
        .navigationTitle("Tankbuch")
        .navigationBarTitleDisplayMode(.inline)
        .navBarStyle()
    }

    private func numberRow(_ title: String, _ hint: String, _ value: Binding<Double?>) -> some View {
        LabeledContent(title) {
            TextField(hint, value: value, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 140)
        }
    }

    private func row(_ e: FuelEntry, _ r: FuelResult?) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(Format.day(e.date))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.fg)
                Text(detail(e))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundColor(Theme.muted)
            }
            Spacer()
            if let r {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.1f l/100", r.per100))
                        .font(.system(size: 15, weight: .bold).monospacedDigit())
                        .foregroundColor(Theme.fg)
                    Text(String(format: "%.0f km", r.km) + (r.gps ? " (GPS)" : ""))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundColor(Theme.muted)
                }
            }
        }
    }

    private func detail(_ e: FuelEntry) -> String {
        var parts = [String(format: "%.1f l", e.liters)]
        if !e.full { parts.append("nicht voll") }
        if let o = e.odometer { parts.append(String(format: "%.0f km", o)) }
        if let p = e.price, e.liters > 0 { parts.append(String(format: "%.2f €/l", p / e.liters)) }
        return parts.joined(separator: " · ")
    }

    private func add() {
        guard let l = liters, l > 0 else { return }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        fuel.add(FuelEntry(date: date, liters: l, odometer: (odometer ?? 0) > 0 ? odometer : nil,
                           full: full, price: (price ?? 0) > 0 ? price : nil))
        liters = nil
        price = nil
        odometer = nil
        date = Date()
    }
}
