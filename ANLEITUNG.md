# Citroën Anzeige – iOS-App

Native SwiftUI-App. Verbindet sich per Bluetooth LE mit der Bridge
(`ESP32_BLE_Bridge_V1`, Gerätename „Citroen-Anzeige“) und zeigt Lambda,
Öldruck, Öltemperatur, Tank und den Lambda-Verlauf der letzten 60 s.

## .ipa bauen (für SideStore)

1. Xcode aus dem App Store installieren und einmal starten.
2. Ordner auf den Mac kopieren, Terminal öffnen:
   ```
   cd CitroenAnzeige-iOS
   chmod +x build_ipa.sh
   ./build_ipa.sh
   ```
3. `CitroenAnzeige.ipa` per AirDrop aufs iPhone, in SideStore mit **+** installieren.
   SideStore erneuert die App automatisch vor Ablauf der 7 Tage.

Fehlt XcodeGen, installiert das Skript es über Homebrew.

## Direkt aus Xcode aufs iPhone (ohne SideStore)

```
xcodegen generate
open CitroenAnzeige.xcodeproj
```
Target „CitroenAnzeige“ → *Signing & Capabilities* → Team: deine Apple-ID.
iPhone per Kabel anschließen, oben als Ziel wählen, ▶ drücken.
Auf dem iPhone einmal *Einstellungen → Allgemein → VPN & Geräteverwaltung*
dem Entwickler vertrauen. Läuft dann 7 Tage.

## Wenn etwas hakt

- **„iOS … is not installed“**: `xcodebuild -downloadPlatform iOS` ausführen.
- **Bundle-ID schon vergeben** (nur beim Weg über Xcode): in `project.yml`
  `PRODUCT_BUNDLE_IDENTIFIER` ändern, `xcodegen generate` erneut.
- **Kein Bluetooth-Zugriff**: Einstellungen → Citroën → Bluetooth erlauben.

## Verhalten

- Sucht beim Start nach der Bridge und der 123ignition und verbindet sich
  mit beiden automatisch.
- Fällt eine Verbindung weg, verbindet iOS von selbst neu, sobald das Gerät
  wieder Strom hat.
- Bildschirm bleibt an, solange eine Verbindung besteht.
- „Demo-Werte zeigen“ zum Testen ohne Hardware (auch die 123-Werte laufen
  dabei durch den echten Parser).

## 123ignition (123\TUNE+)

Gelesen werden Drehzahl, Zündwinkel, Saugrohrdruck, Bordspannung,
Spulenstrom, Modultemperatur und ob der Tuning-Modus aktiv ist.
Protokoll: reverse engineered von iafilius/123Tune-plus-Simulator,
Details in `Sources/Tune123.swift`.

- Die 123 nimmt nur **eine** Bluetooth-Verbindung an. Läuft die 123-App,
  findet diese App die Zündung nicht (und umgekehrt).
- Die App sendet nur Keepalives (`$`) und schaltet das Funkmodul in den
  Datenmodus. Sie liest keinen Pincode und ändert nichts an Kurven,
  Wegfahrsperre oder Tuning.
- Erscheint „123ignition: keine Daten“, obwohl verbunden: Zündung an?
  Der Simulator sendet sofort nach dem Verbinden; ob die echte 123 dafür
  noch eine Anfrage braucht, ist nicht dokumentiert.
- Drehzahlgrenzen für die Farben stehen in `Sources/Theme.swift`
  (`rpmWarn`, `rpmCrit`, `rpmScaleMax`).
