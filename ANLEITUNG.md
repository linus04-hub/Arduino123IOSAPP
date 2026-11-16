# Citroën Anzeige – iOS-App

Native SwiftUI-App für den 2CV6. Verbindet sich per Bluetooth LE mit der Bridge
(`ESP32_BLE_Bridge_V3`, Gerätename „Citroen-Anzeige“) und der 123ignition und zeigt
Lambda, Öldruck, Öltemperatur, Tank, Drehzahl, Zündwinkel, Saugrohrdruck und Bordnetz.
Ab iOS 16.1.

## Aufbau

| Tab | Inhalt |
|---|---|
| **Live** | Anzeigen in vier Ansichten (Standard, Rundinstrumente, Fokus, Abstimmung), oben rechts umschaltbar. Unten die Leiste mit Aufnahme, GPS-Tempo und **Markierung**. |
| **Fahrten** | Tankbuch und alle aufgezeichneten Fahrten. Pro Fahrt: Zusammenfassung, Karte, Diagramm mit wählbarem Wert, Gemisch je Betriebsbereich, Markierungen mit Werten und Notiz, CSV teilen, als Messreihe speichern. |
| **Abstimmung** | **Check** (Gemisch-Check: je Betriebsbereich eine Zeile mit Ampel, Antippen öffnet Belege, Ursachen und Maßnahmen), **Kennfeld** (weiche Farbkarte: Lambda, Abstand zum Ziel, Streuung, Anzahl, Zündung), **Zündung** (Zündwinkel über Drehzahl), **Vergleich** (zwei Messreihen vorher/nachher), **Mehr** (Bedüsung und Logbuch, Leerlauf-Assistent, Düsen-Rechner, Züge unter Last, Gasstöße, Zündkurven der 123). |
| **Einstellungen** | Nachtmodus, Ansicht, Live-Aktivität, GPS, automatische Aufnahme, **Gemisch** (Ziel-Lambda), **Warnungen und Fahrzeug**, Bridge-Version und „Bridge aktualisieren“, **Diagnose**. |

## Gemisch abstimmen (ab Version 2.0)

Ein Vergasermotor soll nicht überall Lambda 1 fahren. Die App bewertet deshalb gegen ein
**Ziel-Lambda je Betriebsbereich** (Einstellungen › Gemisch, Vorgabe: Leerlauf 0.95,
Teillast 1.00, Übergang 0.95, Vollgas 0.88). Den Bereich schätzt sie aus Drehzahl und
Saugrohrdruck der 123:

| Bereich | Grenzen | Vergaserkreis |
|---|---|---|
| Leerlauf | unter 1450 U/min, 30–70 kPa | Leerlaufdüse und Gemischschraube |
| Teillast | 30–70 kPa, dazu 70–90 kPa unter 2250 U/min | Hauptdüse Stufe 1 |
| Übergang | 70–90 kPa bei 2250–3750 U/min | Leerlauf-/Übergangsdüse Stufe 2 |
| Vollgas unten / oben | ab 90 kPa, geteilt bei 3500 U/min | Hauptdüse und Luftkorrektur Stufe 2 |
| Schiebebetrieb | unter 30 kPa | ohne Ziel |

- **Live**: Die Lambda-Karte nennt den Bereich („Vollgas oben · passt“), das grüne Fenster der
  Skala wandert zum jeweiligen Ziel. Ohne 123 gelten die festen Grenzen um 1.00 wie auf dem
  Display im Auto. Abschaltbar unter Einstellungen › Gemisch.
- **Ruhige Fahrt**: Für Kennfeld und Check zählen, sobald genug davon da ist, nur Werte bei
  ruhigem Gas (Saugrohrdruck ±3 kPa, Drehzahl ±250 U/min über 1,5 s) und warmem Motor (Öl ab
  60 °C). Gasstöße, Schalten und Kaltlauf verfälschen den Mittelwert sonst. Im Kennfeld mit
  „Nur ruhige Fahrt, Motor warm“ umschaltbar.
- **Gemisch-Check** (Abstimmung › Check): je Bereich Wert, Ziel und Urteil. Die Detailseite zeigt
  Belege (Lambda je 500 U/min, Verteilung), wahrscheinliche Ursachen, Maßnahmen in sinnvoller
  Reihenfolge und, wenn die Düsen eingetragen sind, die rechnerische neue Größe. Dazu Kaltlauf
  (Lambda über der Öltemperatur), Gasstoß und Schiebebetrieb. Oben wählbar: „Aktuell“ oder eine
  gespeicherte Messreihe. Die Regeln sind Werkstatt-Faustregeln, kein Prüfstand.
- **Bedüsung und Logbuch** (Mehr): Düsen, Gemischschraube und Leerlaufdrehzahl eintragen.
  „Eintragen“ hält jede Änderung mit Datum fest und sichert auf Wunsch die bisherige Messreihe
  und beginnt eine neue. So lässt sich unter „Vergleich“ sehen, was ein Umbau gebracht hat.
  Ablage: `Vergaser.json`.
- **Züge unter Last** (Mehr): erkennt Vollgas-Phasen von selbst (Saugrohrdruck über 80 kPa, mindestens
  3 s, Drehzahl steigt um 600 U/min). Zeigt Lambda über der Drehzahl, ab wo es mager wird, wie
  schnell der Motor hochdreht und eine **geschätzte Leistung am Rad** aus Beschleunigung, Masse
  und Fahrwiderständen (nur auf ebener Strecke ohne Wind brauchbar, zum Vergleichen vorher/nachher).
  Dauervollgas ab 8 s: Steigt Lambda mit der Zeit, fehlt Sprit von der Pumpe.
- **Gasstöße**: Mit der 123 gilt als Gasstoß ein Sprung des Saugrohrdrucks um mindestens 15 kPa
  aus ruhiger Fahrt. So zählen auch die sauberen. Fett gilt erst unter Lambda 0.80.
- **Warnungen**: Öldruck unter 1.0 bar ab 1500 U/min, Öl ab 145 °C, mager unter Last (Lambda ab
  1.05 bei viel Gas ab 2500 U/min), Überdrehzahl, Lichtmaschine lädt nicht, Überspannung. Groß
  über den Anzeigen, mit Vibration, auf Wunsch Ton, und als Markierung in der laufenden Aufnahme.
  Einzeln abschaltbar unter Einstellungen › Warnungen und Fahrzeug.
- **Tankbuch** (Fahrten): Verbrauch von Volltanken zu Volltanken, mit Kilometerstand oder aus
  den GPS-Kilometern der Fahrten dazwischen. Ablage: `Tankbuch.json`.

## Diagnose (Einstellungen › Diagnose)

Für die Fehlersuche an Sensoren und Verbindungen:

- **Selbsttest**: prüft laufend, ob die Werte zusammenpassen. Zum Beispiel Saugrohrdruck bei
  stehendem Motor (muss dem Luftdruck entsprechen, 95–102 kPa), Öldruck bei stehendem Motor
  (etwa 0 bar), Datenraten, die Kette Arduino → Display → Bridge, Bordspannung je nach Motorlauf.
- **Anzeige (Bridge)**: Firmware, Empfangsstärke, Pakete je Sekunde, Rohwerte und Status-Bits.
- **123ignition**: Bauart (BRSP oder Nordic UART), Empfang, je Frame-Typ Anzahl, Rate, letztes
  Rohbyte und umgerechneter Wert, übersprungene Bytes, unbekannte Frame-Typen.
- **Protokoll**: Verbinden, Trennen, Lesebefehle und deren Antworten, zum Teilen als Text.
  Antworten der 123 stehen dort nur als Muster (`hh_hh_…`), nie mit Inhalt, damit der Pincode
  nicht lesbar wird.

## Funktionen

- **Fahrtenschreiber**: startet automatisch, sobald der Motor 5 s läuft (mit 123: Drehzahl,
  ohne: Öldruck ab 0.5 bar), und endet 1 min nach dem Abstellen. Speichert alle Werte 4× pro Sekunde
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
  *Lambda* zeigt das mittlere Gemisch (blau fett, grün 1.00, orange/rot mager), *Δ Ziel* den
  Abstand zum Ziel-Lambda des jeweiligen Bereichs (grün passt, blau zu fett, rot zu mager), *Streuung*
  wie unruhig es ist, *Anzahl* wie viele Werte drinstecken. Die Streuung wird ab Version 1.2
  erfasst; ältere Messreihen bleiben in dieser Ansicht dunkel.
- **Zündwinkel im Kennfeld**: Ansicht „Zündung“ oder Schalter „Zündwinkel einblenden“, dann steht
  der mittlere Zündwinkel in jeder Zelle über der Lambda-Karte. Wird ab Version 1.4 erfasst.
- **Zündkurven der 123** (Abstimmung › Werkzeuge oder unter „Zündung“): liest die programmierte
  Fliehkraft- und Unterdruckkurve, ab welcher Drehzahl der Unterdruck wirkt, Drehzahlbegrenzer,
  Wegfahrsperre und Firmware aus der Zündung, wie es die 123-App beim Verbinden tut. Nur bei
  stehendem Motor, automatisch beim Verbinden (abschaltbar) oder per Knopf. Dazu Soll gegen Ist
  und die Messpunkte über den Kurven. Unter „Zündung“ liegt die Fliehkraftkurve gestrichelt über
  der gemessenen.
- **Leerlauf-Assistent** (Abstimmung › Werkzeuge): Gemischschraube in kleinen Schritten drehen
  und den passenden Knopf tippen. Die App wartet 10 s, mittelt dann 10 s Lambda und Drehzahl und
  markiert die Stellung mit der höchsten Drehzahl bei ruhigem Lambda.
- **Gasstöße**: zeigt, wie weit und wie lange das Gemisch beim Gasgeben mager oder fett wird.
  Hilft bei der Beschleunigerpumpe. Ohne Saugrohrdruck der 123 nur eine Schätzung.
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

- **Werte passen nicht oder fehlen**: Einstellungen › Diagnose. Der Selbsttest sagt, welcher
  Sensor oder welche Verbindung auffällt; das Protokoll lässt sich teilen.
- **Anzeigen bleiben leer nach Signalverlust**: gewollt. Kommt 3 s (Bridge) bzw. 5 s (123)
  nichts Neues, zeigt die App Striche statt des letzten Werts.
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
- Die App sendet nur Keepalives (`$`) und die Lesebefehle der 123-App (`10@` bis `13@`, `v@`).
  Sie ändert nichts an Kurven, Begrenzer, Wegfahrsperre oder Tuning.
- In Block `11@` steckt neben Begrenzer und Kurvenpunkt 8–10 auch der Pincode. Die App nullt
  ihn direkt beim Empfang, zeigt und speichert ihn nicht.
- Die Lesebefehle sind für die ältere 123 (BRSP) belegt. Antwortet eine neuere 123 nicht,
  steht unter „Zündkurven der 123“ ein Hinweis, sonst passiert nichts.
- Drehzahlgrenzen für die Farben stehen in `Sources/Theme.swift`
  (`rpmWarn`, `rpmCrit`, `rpmScaleMax`).
