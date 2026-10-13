import Foundation

// ── 123ignition (123\TUNE+) — nur LESEN ──────────────────────────────
//
// Protokoll aus dem Simulator von iafilius/123Tune-plus-Simulator
// (reverse engineered, ESP32-Arduino/…/123tune.ino, RX.ino, ble.ino).
//
// Funkmodul: BlueRadios "BRSP" (serielle Schnittstelle ueber BLE)
//   Mode  (read/write):  0x01 = Datenmodus (schreibt auch die 123-App beim Start)
//   RX    (write):       Handy → Zuendung
//   TX    (notify):      Zuendung → Handy, Live-Daten als Textstrom
//
// Live-Daten: 5-Byte-Frames, laufend hintereinander gesendet
//   [Typ] [Hex hoch] [Hex tief] [Pruefsumme] [' ' oder '\r']
//   Pruefsumme = Typ + 0x10 + (Hex hoch − '0') + (Hex tief − '0')
//   Beispiel aus einem Mitschnitt: "0" "1" "4" "E" " "  →  0x14 × 50 = 1000 U/min
//
//   Typ  Inhalt           Umrechnung (Byte = zwei Hex-Zeichen)
//   '0'  Drehzahl         Byte × 50            U/min
//   '1'  Zuendwinkel      Byte × 0,2           ° vor OT
//   '2'  Saugrohrdruck    Byte                 kPa absolut (100 = kein Unterdruck)
//   '3'  Modultemperatur  Byte − 30            °C
//   '4'  Tuning-Modus     Byte 0x11 = aktiv, 0x10 = aus
//   '5'  Spulenstrom      Byte × 1,85 / 16     A
//   'A'  Bordspannung     Byte × 14,1 / 64     V
//   'B'  unbekannt        wird ignoriert
//
// Die App schickt nur '$' (Keepalive, so wie die 123-App) und setzt den
// Datenmodus. Keine Befehle, die Kurven, Pincode, Wegfahrsperre oder
// Tuning veraendern.

enum Tune123 {
    static let serviceUUIDString = "DA2B84F1-6279-48DE-BDC0-AFBEA0226079"
    static let modeUUIDString    = "A87988B9-694C-479C-900E-95DFA6C00A24"
    static let rxUUIDString      = "BF03260C-7205-4C25-AF43-93B1C299D159"
    static let txUUIDString      = "18CDA784-4BD3-4370-85BB-BFED91EC86AF"

    // Neuere 123\TUNE+ (Albertronic, Nordic-Chip): Nordic UART Service.
    // Gleicher Datenstrom wie oben, nur ohne Mode-Characteristic.
    static let nusServiceUUIDString = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
    static let nusRXUUIDString      = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"  // write
    static let nusTXUUIDString      = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"  // notify
    static let albertronicID: UInt16 = 0x091A   // Hersteller-ID in den Werbedaten

    static let dataMode: UInt8   = 0x01
    static let hello             = Data("$$\r".utf8)  // wie der Anfang der 123-App, ohne Kurvenabfrage
    static let keepalive         = Data("$".utf8)

    /// Erster Drehzahlwert nach dem Verbinden ist ein Platzhalter (0xBE → 9500).
    static let maxPlausibleRPM: Double = 9000
}

enum Tune123Frame: Equatable {
    case rpm(Double)
    case advance(Double)
    case mapKPa(Double)
    case moduleTemp(Double)
    case tuningMode(Bool)
    case coilCurrent(Double)
    case voltage(Double)
    case other(UInt8)
}

/// Zerlegt den Byte-Strom. Frames koennen auf mehrere Notifications verteilt
/// oder zu mehreren in einer stecken; Muell dazwischen wird uebersprungen.
struct Tune123Parser {
    private var buffer: [UInt8] = []

    mutating func reset() { buffer.removeAll() }

    mutating func feed(_ data: Data) -> [Tune123Frame] {
        buffer.append(contentsOf: data)
        var frames: [Tune123Frame] = []
        var i = 0
        while buffer.count - i >= 5 {
            if let f = Self.decode(buffer[i], buffer[i + 1], buffer[i + 2], buffer[i + 3], buffer[i + 4]) {
                frames.append(f)
                i += 5
            } else {
                i += 1
            }
        }
        buffer.removeFirst(i)   // hoechstens 4 Bytes bleiben fuer den naechsten Aufruf
        return frames
    }

    static func hexValue(_ c: UInt8) -> Int? {
        switch c {
        case 0x30...0x39: return Int(c) - 0x30
        case 0x41...0x46: return Int(c) - 0x37
        default:          return nil
        }
    }

    static func checksum(_ type: UInt8, _ hi: UInt8, _ lo: UInt8) -> UInt8 {
        UInt8(truncatingIfNeeded: Int(type) + 0x10 + (Int(hi) - 0x30) + (Int(lo) - 0x30))
    }

    static func decode(_ type: UInt8, _ hi: UInt8, _ lo: UInt8, _ sum: UInt8, _ end: UInt8) -> Tune123Frame? {
        guard end == 0x20 || end == 0x0D,
              let h = hexValue(hi), let l = hexValue(lo),
              checksum(type, hi, lo) == sum else { return nil }
        let v = Double(h * 16 + l)
        switch type {
        case 0x30: return .rpm(v * 50)
        case 0x31: return .advance(v * 0.2)
        case 0x32: return .mapKPa(v)
        case 0x33: return .moduleTemp(v - 30)
        case 0x34: return .tuningMode((h * 16 + l) & 0x01 == 0x01)
        case 0x35: return .coilCurrent(v * 1.85 / 16)
        case 0x41: return .voltage(v * 14.1 / 64)
        case 0x42: return .other(type)
        default:   return nil
        }
    }

    /// Gegenrichtung, nur fuer den Demo-Modus
    static func encode(type: UInt8, byte: Int) -> [UInt8] {
        let b = max(0, min(255, byte))
        let digits = Array("0123456789ABCDEF".utf8)
        let hi = digits[b >> 4], lo = digits[b & 0x0F]
        return [type, hi, lo, checksum(type, hi, lo), 0x20]
    }
}

/// Letzter bekannter Stand; Felder bleiben nil, bis der erste Frame dieses Typs kam.
struct TuneReading: Equatable {
    var rpm: Double?
    var advance: Double?
    var mapKPa: Double?
    var moduleTemp: Double?
    var tuningMode: Bool?
    var coilCurrent: Double?
    var voltage: Double?

    mutating func apply(_ f: Tune123Frame) {
        switch f {
        case .rpm(let v):         if v <= Tune123.maxPlausibleRPM { rpm = v }
        case .advance(let v):     advance = v
        case .mapKPa(let v):      mapKPa = v
        case .moduleTemp(let v):  moduleTemp = v
        case .tuningMode(let b):  tuningMode = b
        case .coilCurrent(let v): coilCurrent = v
        case .voltage(let v):     voltage = v
        case .other:              break
        }
    }
}

/// Erzeugt Demo-Frames in der Reihenfolge, wie sie im Mitschnitt auftauchen,
/// und zerhackt den Strom absichtlich in zufaellige Stuecke.
struct Tune123Demo {
    private var t: Double = 0
    private var step = 0
    private var pending: [UInt8] = []
    private let order: [UInt8] = [0x30, 0x31, 0x32, 0x30, 0x33, 0x34, 0x30, 0x35, 0x41, 0x42]

    mutating func next() -> Data {
        t += 0.25
        let rpm = max(800, 2000 + 1500 * sin(t / 5) + Double.random(in: -60...60))
        let map = min(100, max(30, 62 + 30 * sin(t / 5 + 1.2)))
        // grob wie eine Fliehkraft- plus Unterdruckverstellung
        let advance = 8 + min(24, max(0, (rpm - 800) / 3200 * 24)) + max(0, (90 - map) / 60 * 10)

        let type = order[step % order.count]
        step += 1
        let byte: Int
        switch type {
        case 0x30: byte = Int((rpm / 50).rounded())
        case 0x31: byte = Int((advance / 0.2).rounded())
        case 0x32: byte = Int(map.rounded())
        case 0x33: byte = Int(min(70, 25 + t * 0.1).rounded()) + 30
        case 0x34: byte = 0x10
        case 0x35: byte = Int((2.8 * 16 / 1.85).rounded())
        case 0x41: byte = Int((13.9 * 64 / 14.1).rounded())
        default:   byte = 0x45
        }
        pending += Tune123Parser.encode(type: type, byte: byte)

        let n = min(pending.count, Int.random(in: 1...12))
        let chunk = Data(pending.prefix(n))
        pending.removeFirst(n)
        return chunk
    }
}
