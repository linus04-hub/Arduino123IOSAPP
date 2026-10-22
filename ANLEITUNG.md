# Citroën Anzeige – iOS-App

Native SwiftUI-App für den 2CV6. Verbindet sich per Bluetooth LE mit der Bridge
(`ESP32_BLE_Bridge_V2`, Gerätename „Citroen-Anzeige“) und der 123ignition und zeigt
Lambda, Öldruck, Öltemperatur, Tank, Drehzahl, Zündwinkel, Saugrohrdruck und Bordnetz.
Ab iOS 16.1.

## Aufbau

| Tab | Inhalt |
|---|---|
| **Live** | Anzeigen in vier Ansichten (Standard, Rundinstrumente, Fokus, Abstimmung), oben rechts umschaltbar. Unten die Leiste mit Aufnahme, GPS-Tempo und **Markierung**. |
| **Fahrten** | Alle aufgezeichneten Fahrten. Pro Fahrt: Zusammenfassung, Karte, Diagramm mit wählbarem Wert, Markierungen mit Werten und Notiz, CSV teilen, als Messreihe speichern. |
| **Abstimmung** | **Kennfeld** als weiche Farbkarte, umschaltbar zwischen Lambda, Streuung und Anzahl; Antippen zeigt Wert und Anzahl der Zelle, **Zündung** (Zündwinkel über Drehzahl), **Vergleich** (zwei Messreihen: Kennfeld-Differenz und Kurven vorher/nachher), **Werkzeuge** (Leerlauf-Assistent, Gasstöße, Düsen-Rechner). |
| **Einstellungen** | Nachtmodus, Ansicht, Live-Aktivität, GPS, automatische Aufnahme, Bridge-Version und „Bridge aktualisieren“. |

## Funktionen

- **Fahrtenschreiber**: startet automatisch, sobald der Motor 5 s läuft (Drehzahl der 123
  oder Öldruck), und endet 1 min nach dem Abstellen. Speichert alle Werte 4× pro Sekunde
  als CSV (`;` und Dezimalkomma, geht direkt in Excel auf) in
  *Dateien › Auf meinem iPhone › Citroën › Fahrten*.
- **Markierungen**: Ein Tipp auf „Markierung“ setzt einen Zeitstempel. Im Fahrtdetail
  stehen dazu Lambda, Drehzahl, Tempo, Last und Öltemperatur, und du kannst eine Notiz eintragen.
- **GPS**: Tempo und Strecke vom iPhone. Läuft nur, solange aufgezeichnet wird oder ein Gerät
  verbunden ist, und auch bei gesperrtem Bildschirm.
- **Live-Aktivität**: Lambda, Öltemperatur, Öldruck, Drehzahl und Tempo auf dem
  Sperrbildschirm und in der Dynamic Island, mit Warnhinweis bei kritischen Werten.
- **Messreihen**: „Aktuell“ sammelt laufend. Speichern unter einem Namen (z. B. „HD 115“),
  dann unter *Vergleich* zwei Reihen gegenüberstellen. Fahrten lassen sich nachträglich als
  Messreihe speichern. Ablage: *Dateien › Citroën › Messreihen*.
- **Kennfeld**: Farbkarte über Drehzahl und Saugrohrdruck, zwischen den Zellen weich gemischt.
  *Lambda* zeigt das mittlere Gemisch (blau fett, grün 1.00, orange/rot mager), *Streuung*
  wie unruhig es ist, *Anzahl* wie viele Werte drinstecken. Die Streuung wird ab Version 1.2
  erfasst; ältere Messreihen bleiben in dieser Ansicht dunkel.
- **Zündwinkel im Kennfeld**: Ansicht „Zündung“ oder Schalter „Zündwinkel einblenden“, dann steht
  der mittlere Zündwinkel in jeder Zelle über der Lambda-Karte. Wird ab Version 1.4 erfasst.
- **Leerlauf-Assistent** (Abstimmung › Werkzeuge): Gemischschraube in kleinen Schritten drehen
  und den passenden Knopf tippen. Die App wartet 10 s, mittelt dann 10 s Lambda und Drehzahl und
  markiert die Stellung mit der höchsten Drehzahl bei ruhigem Lambda.
- **Gasstöße**: erkennt zügiges Gasgeben (Lambda schlägt aus, Drehzahl steigt danach) und zeigt,
  wie weit und wie lange das Gemisch mager oder fett wird. Hilft bei der Beschleunigerpumpe.
  Ohne Drosselklappen-Sensor eine Schätzung.
- **Düsen-Rechner**: d_neu ≈ d_alt × √(λ_ist / λ_soll), mit λ_ist aus dem Kennfeld je Vergaserkreis
  oder aus einer angetippten Zelle. Faustregel, Luftkorrektur und Schwimmerstand spielen mit.
- **Bridge aktualisieren** (ab Bridge v3): Einstellungen › Bridge › „Bridge aktualisieren“.
  Die Bridge öffnet das WLAN „Citroen-Update“ (Passwort `2cv-bridge`), dann in Safari
  192.168.4.1 öffnen und die .bin aus der Arduino IDE hochladen. Kein Ausbauen nötig.
- **Nachtmodus**: dunkel und warm, an, aus oder automatisch zwischen 20 und 7 Uhr.
- Werte laufen mit Bildschirmrate (bis 120 Hz) weich mit.
- „Demo-Werte zeigen“ zum Testen ohne Hardware. Demo-Werte werden nicht aufgezeichnet.

## Installieren und Updates über AltStore

Jeder Build auf dem Hauptzweig veröffentlicht ein Release mit der .ipa und einer
AltStore-Quelle. Die Quelle einmal in AltStore hinzufügen (Tab „Quellen“ › „+“):

```
https://github.com/linus04-hub/Arduino123IOSAPP/releases/latest/download/altstore-source.json
```

Danach steht die App dort zum Installieren, und neue Versionen erscheinen unter
„My Apps“ mit „Aktualisieren“. Die Build-Nummer zählt bei jedem Build hoch.

## .ipa bauen

Über GitHub (Windows): Dateien ins Repo hochladen, **Actions → Build IPA** baut die .ipa,
unten unter **Artifacts** herunterladen, mit AltStore installieren.

Auf dem Mac:
```
cd CitroenAnzeige-iOS
chmod +x build_ipa.sh
./build_ipa.sh
```
Fehlt XcodeGen, installiert das Skript es über Homebrew.

Die App enthält eine Widget-Erweiterung für die Live-Aktivität. Mit kostenloser Apple-ID
braucht sie deshalb zwei App-IDs (App + Erweiterung); erlaubt sind 10 neue pro Woche.

## Wenn etwas hakt

- **„iOS … is not installed“**: `xcodebuild -downloadPlatform iOS` ausführen.
- **Kein Bluetooth-Zugriff**: Einstellungen → Citroën → Bluetooth erlauben.
- **Kein Tempo**: Einstellungen → Datenschutz → Ortungsdienste → Citroën → „Beim Verwenden“.
- **Keine Live-Aktivität**: Einstellungen → Citroën → Live-Aktivitäten an, und in der App
  unter Einstellungen eingeschaltet. Sie startet, sobald Anzeige oder 123 verbunden ist
  und die App einmal im Vordergrund war.

## 123ignition (123\TUNE+)

Gelesen werden Drehzahl, Zündwinkel, Saugrohrdruck, Bordspannung,
Spulenstrom, Modultemperatur und ob der Tuning-Modus aktiv ist.
Protokoll: reverse engineered von iafilius/123Tune-plus-Simulator,
Details in `Sources/Tune123.swift`. Ältere 123 funken über BlueRadios BRSP,
neuere (Hersteller Albertronic) über den Nordic UART Service. Die App erkennt
beide, die Daten sind gleich.

- Die 123 nimmt nur **eine** Bluetooth-Verbindung an. Läuft die 123-App,
  findet diese App die Zündung nicht (und umgekehrt).
- Die App sendet nur Keepalives (`$`). Sie liest keinen Pincode und ändert nichts
  an Kurven, Wegfahrsperre oder Tuning.
- Drehzahlgrenzen für die Farben stehen in `Sources/Theme.swift`
  (`rpmWarn`, `rpmCrit`, `rpmScaleMax`).
