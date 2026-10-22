// Prueft den 123-Parser ohne Geraet. Laeuft im CI vor dem Build:
//   cat Sources/Tune123.swift Tests/Tune123Check.swift > check.swift && swift check.swift
// Testdaten: Mitschnitte aus iafilius/123Tune-plus-Simulator (ble.ino, str_resp*).

// (Foundation kommt mit Tune123.swift)

var failures = 0
func check(_ ok: Bool, _ what: String) {
    if !ok { failures += 1; print("FEHLER: " + what) }
}

func feedAll(_ s: [UInt8], chunks: [Int]) -> [Tune123Frame] {
    var p = Tune123Parser()
    var out: [Tune123Frame] = []
    var i = 0, c = 0
    while i < s.count {
        let n = min(s.count - i, max(1, chunks[c % chunks.count]))
        out += p.feed(Data(s[i..<(i + n)]))
        i += n
        c += 1
    }
    return out
}

func blocks(_ frames: [Tune123Frame]) -> [Int: [UInt8]] {
    var b: [Int: [UInt8]] = [:]
    for f in frames { if case .block(let n, let bytes) = f { b[n] = bytes } }
    return b
}

func live(_ frames: [Tune123Frame]) -> [Tune123Frame] {
    frames.filter {
        switch $0 { case .block, .version: return false; default: return true }
    }
}

// Mitschnitte (Antworten einer echten 123, BRSP)
let sniff0 = Array("10@\rFF FF 0A 00 0E 00 10 00 14 14 1E 3C 24 55 3C 96 103F3\r".utf8)
let sniff1 = Array("11@\r5A A5 A0 A5 FF FF 37 38 33 32 00 FF FF FF 16 5A 11883\r".utf8)
let sniff2 = Array("12@\rFF FF 00 37 1D 37 1E 37 28 37 58 00 64 00 C8 00 124C1\r".utf8)
let sniff3 = Array("13@\rFF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF 13FF0\r".utf8)
let sniffV = Array("v@\r403A6441-10-45 ".utf8)
let liveA  = Array("014E 264L A41V 0BEg ".utf8)

// 1. Einzelne Antworten, am Stueck und Byte fuer Byte
for (n, s) in [sniff0, sniff1, sniff2, sniff3].enumerated() {
    for chunks in [[1000], [1], [20], [7, 3, 11]] {
        let b = blocks(feedAll(s, chunks: chunks))
        check(b[n]?.count == 16, "Block \(n) nicht erkannt (Stuecke \(chunks))")
    }
}
let b1 = blocks(feedAll(sniff1, chunks: [20]))[1] ?? []
check(b1.count == 16 && b1[6...9].allSatisfy { $0 == 0 }, "Pincode nicht genullt")
check(b1.count == 16 && b1[14] == 0x16 && b1[15] == 0x5A, "Block 1 Startdrehzahl/Begrenzer falsch")

let v = feedAll(sniffV, chunks: [5])
check(v == [.version("41-10-45")], "Version nicht erkannt: \(v)")

// 2. Programm aus den Mitschnitten
var all = sniff0 + sniff1 + sniff2 + sniff3 + sniffV
let frames = feedAll(all, chunks: [20])
var versionText: String?
for f in frames { if case .version(let t) = f { versionText = t } }
let prog = Tune123Program.decode(blocks(frames), version: versionText)
check(prog != nil, "Programm nicht dekodiert")
if let p = prog {
    let adv = p.advance.map { [$0.x, $0.deg] }
    let advWant: [[Double]] = [[500, 0], [700, 0], [800, 0], [1000, 4], [1500, 12], [1800, 17],
                               [3000, 30], [4500, 33], [8000, 33]]
    check(adv.count == advWant.count && zip(adv, advWant).allSatisfy { abs($0[0] - $1[0]) < 0.01 && abs($0[1] - $1[1]) < 0.01 },
          "Fliehkraftkurve falsch: \(adv)")
    let vac = p.vacuum.map { [$0.x, $0.deg] }
    let vacWant: [[Double]] = [[0, 11], [29, 11], [30, 11], [40, 11], [88, 0], [100, 0], [200, 0]]
    check(vac.count == vacWant.count && zip(vac, vacWant).allSatisfy { abs($0[0] - $1[0]) < 0.01 && abs($0[1] - $1[1]) < 0.01 },
          "Unterdruckkurve falsch: \(vac)")
    check(p.vacuumStartRPM == 1100, "Startdrehzahl \(String(describing: p.vacuumStartRPM))")
    check(p.rpmLimit == 4500, "Begrenzer \(String(describing: p.rpmLimit))")
    check(p.immobilizer == nil, "Wegfahrsperre sollte unbekannt sein")
    check(p.version == "41-10-45", "Version im Programm")
    check(p.complete, "Programm nicht vollstaendig")

    // Interpolation wie im Simulator
    check(abs((p.centrifugal(rpm: 1250) ?? -1) - 8) < 0.001, "Interpolation Fliehkraft")
    check(abs((p.vacuumShare(rpm: 2000, kPa: 50) ?? -1) - (11 - 10.0 / 48 * 11)) < 0.001, "Interpolation Unterdruck")
    check(p.vacuumShare(rpm: 1000, kPa: 30) == 0, "Unterdruck unter Startdrehzahl")
    let e = (17 + 200.0 / 1200 * 13) + (11 - 10.0 / 48 * 11)
    check(abs((p.expected(rpm: 2000, kPa: 50) ?? -1) - e) < 0.001, "Soll-Zuendwinkel")
}

// 3. Antworten mitten im Live-Strom, verschieden zerhackt, mit Stoerbytes
let liveFrames = feedAll(liveA, chunks: [1000])
check(liveFrames.count == 4, "Live-Frames Referenz: \(liveFrames)")
all = liveA + Array("\r$".utf8) + sniff0 + liveA + sniff1 + Array("xx".utf8) + liveA + sniff2 + sniff3 + sniffV + liveA
for chunks in [[20], [1], [3, 17, 20, 9], [64]] {
    let f = feedAll(all, chunks: chunks)
    check(blocks(f).count == 4, "Gemischt: nicht alle Bloecke (\(chunks))")
    check(live(f) == liveFrames + liveFrames + liveFrames + liveFrames, "Gemischt: Live-Frames gestoert (\(chunks))")
    check(f.filter { if case .version = $0 { return true }; return false }.count == 1, "Gemischt: Version (\(chunks))")
}

// 4. Falsche Pruefsumme → kein Block
var bad = sniff0
bad[bad.count - 2] = UInt8(ascii: "4")
check(blocks(feedAll(bad, chunks: [20])).isEmpty, "Falsche Pruefsumme akzeptiert")

// 5. Demo-Antworten ergeben die Demo-Programmierung
var demo: [UInt8] = []
for cmd in Tune123.readBlocks + [Tune123.readVersion] { demo += Tune123Demo.response(to: cmd) ?? [] }
let df = feedAll(demo, chunks: [20])
var dv: String?
for f in df { if case .version(let t) = f { dv = t } }
if let d = Tune123Program.decode(blocks(df), version: dv) {
    check(d.advance == Tune123Program.demo.advance, "Demo Fliehkraft")
    check(d.vacuum == Tune123Program.demo.vacuum, "Demo Unterdruck")
    check(d.vacuumStartRPM == 1100 && d.rpmLimit == 4650 && d.immobilizer == false, "Demo Einstellungen")
    check(d.version == "41-10-45", "Demo Version")
} else {
    check(false, "Demo nicht dekodiert")
}
check(Tune123Demo.response(to: Data("55-01A\r".utf8)) == nil, "Demo antwortet auf Schreibbefehl")

// 6. Nur erlaubte Befehle
let allowed = Tune123.readBlocks + [Tune123.readVersion, Tune123.hello, Tune123.keepalive]
check(allowed.map { String(decoding: $0, as: UTF8.self) } == ["10@\r", "11@\r", "12@\r", "13@\r", "v@\r", "$$\r", "$"],
      "Befehlsliste veraendert")

// 7. Zufaelliger Live-Strom: nichts Falsches erkannt, nichts verloren
var rng = UInt64(12345)
func rnd(_ n: Int) -> Int {
    rng = rng &* 6364136223846793005 &+ 1442695040888963407
    return Int((rng >> 33) % UInt64(n))
}
let types: [UInt8] = [0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x41, 0x42]
for _ in 0..<200 {
    var s: [UInt8] = []
    var want = 0
    for _ in 0..<40 {
        s += Tune123Parser.encode(type: types[rnd(types.count)], byte: rnd(256))
        want += 1
        if rnd(10) == 0 { s.append(UInt8(rnd(256))) }    // Stoerbyte
    }
    let f = feedAll(s, chunks: [1 + rnd(20), 1 + rnd(20)])
    check(blocks(f).isEmpty, "Zufall: Block erfunden")
    check(live(f).count >= want - 4 * 5, "Zufall: zu viele Frames verloren (\(live(f).count) von \(want))")
}

if failures == 0 {
    print("Tune123: alle Pruefungen bestanden")
} else {
    print("Tune123: \(failures) Fehler")
    exit(1)
}
