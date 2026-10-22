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
// Lesebefehle (schickt die 123-App bei jedem Verbinden genauso):
//   "10@\r" … "13@\r"  Speicherblock 0 bis 3, je 16 Byte
//   "v@\r"             Spannung, Temperatur, Druck und Versionstext
// Antwort auf "1N@\r" (Mitschnitt aus dem Simulator-Repo):
//   [Echo "1N@\r"] 16 × "HH " "1N" "CCC" "\r"     CCC = Summe der 16 Byte, hex
//   Block 0  Byte 2..15   Fliehkraftkurve Punkt 1–7 (U/min × 50, Grad × 0,2)
//   Block 1  Byte 0..5    Fliehkraftkurve Punkt 8–10
//            Byte 6..9    PINCODE im Klartext → wird beim Zerlegen sofort genullt
//            Byte 10      Wegfahrsperre (0x55 an, 0xAA aus)
//            Byte 14      Unterdruckverstellung ab Drehzahl (× 50)
//            Byte 15      Drehzahlbegrenzer (× 50)
//   Block 2  Byte 2..15   Unterdruckkurve Punkt 1–7 (kPa absolut, Grad × 0,2)
//   Block 3  Byte 0..5    Unterdruckkurve Punkt 8–10
//   0xFF = Punkt nicht belegt.
// Antwort auf "v@\r":  [Echo "v@\r"] 6 Hex-Zeichen, Versionstext, ' '
//
// Die App schickt nur '$' (Keepalive), den Start "$$\r" und die Lesebefehle
// oben. Keine Befehle, die Kurven, Pincode, Wegfahrsperre oder Tuning
// veraendern ("VV-0AA\r", 't', 'a', 'r' werden nie gesendet).

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

    /// Die einzigen Befehle ausser Keepalive: Speicherblock 0–3 lesen, Version lesen
    static let readBlocks: [Data] = (0..<4).map { Data("1\($0)@\r".utf8) }
    static let readVersion       = Data("v@\r".utf8)
    /// Block 1, Byte 6–9: Pincode. Wird nie weitergegeben.
    static let pinBytes          = 6...9

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
    case block(Int, [UInt8])     // Antwort auf "1N@": Blocknummer 0–3, 16 Byte (Pincode genullt)
    case version(String)         // Antwort auf "v@"
}

/// Zerlegt den Byte-Strom. Frames koennen auf mehrere Notifications verteilt
/// oder zu mehreren in einer stecken; Muell dazwischen wird uebersprungen.
struct Tune123Parser {
    private var buffer: [UInt8] = []

    mutating func reset() { buffer.removeAll() }

    enum Match { case found(Tune123Frame, Int), partial, none }

    static let blockLength = 54          // 16 × "HH " + "1N" + "CCC" + "\r"
    static let maxBuffer = 512

    mutating func feed(_ data: Data) -> [Tune123Frame] {
        buffer.append(contentsOf: data)
        if buffer.count > Self.maxBuffer { buffer.removeFirst(buffer.count - Self.maxBuffer) }
        var frames: [Tune123Frame] = []
        var i = 0
        scan: while i < buffer.count {
            for match in [Self.matchBlock, Self.matchVersion] {
                switch match(buffer, i) {
                case .found(let f, let len):
                    frames.append(f)
                    i += len
                    continue scan
                case .partial:
                    break scan           // auf den Rest der Antwort warten
                case .none:
                    break
                }
            }
            guard buffer.count - i >= 5 else { break }
            if let f = Self.decode(buffer[i], buffer[i + 1], buffer[i + 2], buffer[i + 3], buffer[i + 4]) {
                frames.append(f)
                i += 5
            } else {
                i += 1
            }
        }
        buffer.removeFirst(i)
        return frames
    }

    /// Antwort auf "1N@\r" ab Position i (ohne das Echo davor)
    static func matchBlock(_ b: [UInt8], _ i: Int) -> Match {
        let avail = b.count - i
        for k in 0..<min(avail, blockLength) {
            let c = b[i + k]
            let ok: Bool
            switch k {
            case 0..<48:  ok = k % 3 == 2 ? c == 0x20 : hexValue(c) != nil
            case 48:      ok = c == 0x31                  // '1'
            case 49:      ok = (0x30...0x33).contains(c)  // '0'…'3'
            case 50...52: ok = hexValue(c) != nil
            default:      ok = c == 0x0D
            }
            if !ok { return .none }
        }
        guard avail >= blockLength else { return .partial }

        func hex(_ k: Int) -> Int { hexValue(b[i + k]) ?? 0 }
        var bytes = (0..<16).map { hex(3 * $0) * 16 + hex(3 * $0 + 1) }
        let sum = hex(50) * 256 + hex(51) * 16 + hex(52)
        guard bytes.reduce(0, +) == sum else { return .none }
        let n = Int(b[i + 49]) - 0x30
        if n == 1 {
            for j in Tune123.pinBytes { bytes[j] = 0 }    // Pincode nie weitergeben
        }
        return .found(.block(n, bytes.map { UInt8($0) }), blockLength)
    }

    /// Antwort auf "v@\r": Echo, 6 Hex-Zeichen, Versionstext bis ' ' oder '\r'
    static func matchVersion(_ b: [UInt8], _ i: Int) -> Match {
        let head: [UInt8] = [0x76, 0x40, 0x0D]
        let avail = b.count - i
        for k in 0..<min(avail, head.count) where b[i + k] != head[k] { return .none }
        var k = head.count
        while k < head.count + 6 {
            guard k < avail else { return .partial }
            guard hexValue(b[i + k]) != nil else { return .none }
            k += 1
        }
        var text = ""
        while true {
            guard k < avail else { return .partial }
            let c = b[i + k]
            if c == 0x20 || c == 0x0D { break }
            guard text.count < 16, (0x21...0x7E).contains(c) else { return .none }
            text.append(Character(UnicodeScalar(c)))
            k += 1
        }
        guard !text.isEmpty else { return .none }
        return .found(.version(text), k + 1)
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
        case .other, .block, .version: break
        }
    }
}

// ── Programmierung der 123 (aus Block 0–3 und v@) ─────────────────
struct Tune123Point: Codable, Equatable {
    var x: Double       // U/min bzw. kPa
    var deg: Double     // Grad vor OT
}

struct Tune123Program: Codable, Equatable {
    var advance: [Tune123Point] = []    // Fliehkraft: U/min → Grad
    var vacuum: [Tune123Point] = []     // Unterdruck: kPa absolut → Grad
    var vacuumStartRPM: Double?
    var rpmLimit: Double?
    var immobilizer: Bool?
    var version: String?
    var readAt = Date()
    var complete = false                // alle vier Bloecke gelesen
    var isDemo = false

    /// nil, wenn Block 0 fehlt
    static func decode(_ blocks: [Int: [UInt8]], version: String?, at date: Date = Date()) -> Tune123Program? {
        guard let b0 = blocks[0], b0.count == 16 else { return nil }
        let b1 = blocks[1].flatMap { $0.count == 16 ? $0 : nil }
        let b2 = blocks[2].flatMap { $0.count == 16 ? $0 : nil }
        let b3 = blocks[3].flatMap { $0.count == 16 ? $0 : nil }

        var p = Tune123Program()
        var adv = (1...7).map { (b0[2 * $0], b0[2 * $0 + 1]) }
        if let b1 { adv += (0..<3).map { (b1[2 * $0], b1[2 * $0 + 1]) } }
        p.advance = points(adv, x: { Double($0) * 50 })

        var vac: [(UInt8, UInt8)] = []
        if let b2 { vac += (1...7).map { (b2[2 * $0], b2[2 * $0 + 1]) } }
        if let b3 { vac += (0..<3).map { (b3[2 * $0], b3[2 * $0 + 1]) } }
        p.vacuum = points(vac, x: { Double($0) })

        if let b1 {
            p.immobilizer = b1[10] == 0x55 ? true : (b1[10] == 0xAA ? false : nil)
            p.vacuumStartRPM = b1[14] == 0xFF ? nil : Double(b1[14]) * 50
            p.rpmLimit = b1[15] == 0xFF ? nil : Double(b1[15]) * 50
        }
        p.version = version
        p.readAt = date
        p.complete = b1 != nil && b2 != nil && b3 != nil
        return p
    }

    /// 0xFF = Punkt nicht belegt; nur aufsteigende Punkte
    private static func points(_ raw: [(UInt8, UInt8)], x: (UInt8) -> Double) -> [Tune123Point] {
        var out: [Tune123Point] = []
        for (a, d) in raw where a != 0xFF && d != 0xFF {
            let pt = Tune123Point(x: x(a), deg: Double(d) * 0.2)
            if let last = out.last, pt.x < last.x { continue }
            out.append(pt)
        }
        return out
    }

    /// Linear zwischen den Punkten, ausserhalb der erste bzw. letzte Wert
    static func interpolate(_ pts: [Tune123Point], _ x: Double) -> Double? {
        guard let first = pts.first, let last = pts.last else { return nil }
        if x <= first.x { return first.deg }
        if x >= last.x { return last.deg }
        for k in 1..<pts.count where x <= pts[k].x {
            let a = pts[k - 1], b = pts[k]
            guard b.x > a.x else { return b.deg }
            return a.deg + (x - a.x) / (b.x - a.x) * (b.deg - a.deg)
        }
        return last.deg
    }

    func centrifugal(rpm: Double) -> Double? {
        Self.interpolate(advance, rpm)
    }

    /// Anteil der Unterdruckverstellung; 0 unterhalb der Startdrehzahl
    func vacuumShare(rpm: Double, kPa: Double) -> Double? {
        guard !vacuum.isEmpty else { return nil }
        if let s = vacuumStartRPM, rpm < s { return 0 }
        return Self.interpolate(vacuum, kPa)
    }

    /// Soll-Zuendwinkel nach Programm (so rechnet auch der Simulator), ohne Tuning-Versatz
    func expected(rpm: Double, kPa: Double?) -> Double? {
        guard let c = centrifugal(rpm: rpm) else { return nil }
        if vacuum.isEmpty { return c }
        guard let k = kPa, let v = vacuumShare(rpm: rpm, kPa: k) else { return nil }
        return c + v
    }

    /// Werkseinstellung des Simulators, fuer den Demo-Modus
    static let demo: Tune123Program = {
        var p = Tune123Program()
        let adv: [(Double, Double)] = [(500, 0), (700, 0), (800, 0), (1000, 4), (1500, 12), (1800, 17),
                                       (3000, 30), (4500, 33), (8000, 33)]
        let vac: [(Double, Double)] = [(0, 11), (29, 11), (30, 11), (40, 11), (88, 0), (100, 0)]
        p.advance = adv.map { Tune123Point(x: $0.0, deg: $0.1) }
        p.vacuum = vac.map { Tune123Point(x: $0.0, deg: $0.1) }
        p.vacuumStartRPM = 1100
        p.rpmLimit = 4650
        p.immobilizer = false
        p.version = "41-10-45"
        p.complete = true
        p.isDemo = true
        return p
    }()
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
        // so, wie die Demo-Programmierung es vorgibt
        let advance = Tune123Program.demo.expected(rpm: rpm, kPa: map) ?? 10

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

        // Antworten auf Lesebefehle in groesseren Stuecken, wie bei BLE (20 Byte)
        let n = min(pending.count, pending.count > 20 ? 20 : Int.random(in: 1...12))
        let chunk = Data(pending.prefix(n))
        pending.removeFirst(n)
        return chunk
    }

    // Speicherbloecke der Demo-Programmierung (Tune123Program.demo), Pincode als 0000
    static let demoBlocks: [[UInt8]] = [
        [0xFF, 0xFF, 0x0A, 0x00, 0x0E, 0x00, 0x10, 0x00, 0x14, 0x14, 0x1E, 0x3C, 0x24, 0x55, 0x3C, 0x96],
        [0x5A, 0xA5, 0xA0, 0xA5, 0xFF, 0xFF, 0x30, 0x30, 0x30, 0x30, 0xAA, 0xFF, 0xFF, 0xFF, 0x16, 0x5D],
        [0xFF, 0xFF, 0x00, 0x37, 0x1D, 0x37, 0x1E, 0x37, 0x28, 0x37, 0x58, 0x00, 0x64, 0x00, 0xFF, 0xFF],
        [UInt8](repeating: 0xFF, count: 16)
    ]

    /// So antwortet die 123 auf "1N@\r": Echo, 16 × "HH ", "1N", Summe (3 Hex), "\r"
    static func blockResponse(_ n: Int, _ bytes: [UInt8]) -> [UInt8] {
        var s = "1\(n)@\r"
        for b in bytes { s += String(format: "%02X ", b) }
        s += "1\(n)" + String(format: "%03X", bytes.reduce(0) { $0 + Int($1) }) + "\r"
        return Array(s.utf8)
    }

    /// Antwort auf einen Lesebefehl im Demo-Modus, sonst nil
    static func response(to cmd: Data) -> [UInt8]? {
        if let n = Tune123.readBlocks.firstIndex(of: cmd) { return blockResponse(n, demoBlocks[n]) }
        if cmd == Tune123.readVersion { return Array("v@\r434974\(Tune123Program.demo.version ?? "") ".utf8) }
        return nil
    }

    /// Antwort in den laufenden Demo-Strom einreihen (nach dem aktuellen Frame)
    mutating func inject(_ bytes: [UInt8]) {
        let rest = pending.count % 5     // angefangenen Frame erst fertig senden
        pending.insert(contentsOf: bytes, at: rest)
    }
}
