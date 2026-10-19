// Sequent: the Pro DJ Link connection as a Mac menu-bar app.
//
// It does what the Python helper tools/djlink.py (now in git history) did,
// natively and with nothing to install:
// listens for the CDJs' broadcasts, announces itself as player 7 on each
// USB link so the players send their status, asks a deck's database for a
// rekordbox track's title and artist, and serves it all to the Sequent page
// over a WebSocket on 127.0.0.1:8795, accepting only turpin.studio and
// localhost. The messages are the ones the Python helper sent, so the page
// didn't change when the app replaced it.
// It sends the players nothing that changes what they do, except when the
// page asks it to lead them (Leader, below): then it takes the tempo master
// role, so a deck with Sync on follows Sequent.

import AppKit
import Network
import ServiceManagement

// MARK: - Constants

let MAGIC = Array("Qspt1WmJOL".utf8)
// SEQUENT_PORT_OFFSET moves the Pro DJ Link ports, only so a test copy can
// run beside a real one; with it set, no CDJ will hear or be heard.
let PORT_OFFSET = UInt16(ProcessInfo.processInfo.environment["SEQUENT_PORT_OFFSET"] ?? "") ?? 0
let ANNOUNCE_PORT: UInt16 = 50000 + PORT_OFFSET, BEAT_PORT: UInt16 = 50001 + PORT_OFFSET, STATUS_PORT: UInt16 = 50002 + PORT_OFFSET
let DB_PORT: UInt16 = 12523
let VIRTUAL_PLAYER: UInt8 = 7
let WS_PORT = UInt16(ProcessInfo.processInfo.environment["SEQUENT_WS_PORT"] ?? "") ?? 8795
let ORIGINS = ["https://turpin.studio", "http://localhost", "http://127.0.0.1"]
// The pages that may connect: those above, on any port, and any app on a
// turpin.studio subdomain over https (midi.turpin.studio and the like), since
// only the studio can create those. Nothing else, so another site can't read
// what is playing.
func allowed(_ origin: String) -> Bool {
    if ORIGINS.contains(where: { origin == $0 || origin.hasPrefix($0 + ":") }) { return true }
    let prefix = "https://", suffix = ".turpin.studio"
    guard origin.hasPrefix(prefix), origin.hasSuffix(suffix), origin.count > prefix.count + suffix.count else { return false }
    let host = origin.dropFirst(prefix.count).dropLast(suffix.count)
    // One or more DNS labels: letters, digits and inner hyphens.
    return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
        !label.isEmpty && label.first != "-" && label.last != "-" && label.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }
}
let SITE = URL(string: "https://turpin.studio/")!
// This build's version, from its Info.plist (stamped from the release tag).
let APP_VERSION = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
// Which release is the latest, attached to each GitHub release by the release
// pipeline (GitHub redirects this to the newest one), and the page people
// download it from, which shows the latest release's notes and file.
let LATEST = URL(string: "https://github.com/turpin-studio/sequent-bridge/releases/latest/download/latest.json")!
let DOWNLOAD_PAGE = URL(string: "https://turpin.studio/download/")!
// Whether version a is newer than b, both X.Y.Z.
func newer(_ a: String, than b: String) -> Bool {
    let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<3 where (i < x.count ? x[i] : 0) != (i < y.count ? y[i] : 0) { return (i < x.count ? x[i] : 0) > (i < y.count ? y[i] : 0) }
    return false
}
// Deep Symmetry's DJ Link packet analysis, which the decoding is written from.
let RESEARCH = URL(string: "https://djl-analysis.deepsymmetry.org/")!

// MARK: - Decoding (the layouts of Deep Symmetry's DJ Link packet analysis)

typealias Message = [String: Any]

func text(_ p: [UInt8], _ from: Int, _ to: Int) -> String {
    let bytes = p[from..<min(to, p.count)].prefix { $0 != 0 }
    return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
}
func u16(_ p: [UInt8], _ at: Int) -> Int { Int(p[at]) << 8 | Int(p[at + 1]) }
func u32(_ p: [UInt8], _ at: Int) -> Int { Int(p[at]) << 24 | Int(p[at + 1]) << 16 | Int(p[at + 2]) << 8 | Int(p[at + 3]) }
func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }

// The key a CDJ-3000 or 3000X is playing in, as text such as "Bbm", from
// its own status packet; nil for other layouts or no key. Deep Symmetry
// document it (dysentery's vcdj notes, "Key" and "KeyShift"): at 0x15c the
// key with Master Tempo and the tempo slider taken into account, as a note
// (minor keys counted up from A, major keys from C, so a key and its
// relative share a number), then 0 minor or 1 major, then the accidental
// (0xff flat, 0 natural, 1 sharp, 0x64 when the slider has taken it off the
// key); at 0x164 the Key Shift in cents, a signed 64-bit number. The key
// heard is the key moved by the shift, spelt with flats where the key is.
func statusKey(_ p: [UInt8]) -> String? {
    guard p.count >= 0x16c, p[0x15c] < 12, p[0x15d] <= 1 else { return nil }
    let shift = p[0x164..<0x16c].reduce(0) { $0 << 8 | UInt64($1) }
    let cents = Int(Int64(bitPattern: shift))
    let minor = p[0x15d] == 0
    let note = Int(p[0x15c]) + (minor ? 9 : 0) + Int((Double(cents) / 100).rounded())
    let root = (note % 12 + 12) % 12
    let flat = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]
    let sharp = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    return (p[0x15e] == 0xff ? flat : sharp)[root] + (minor ? "m" : "")
}

func parse(port: UInt16, _ p: [UInt8]) -> Message? {
    guard p.count >= 0x22, Array(p.prefix(10)) == MAGIC else { return nil }
    let kind = p[0x0a]
    if port == ANNOUNCE_PORT, kind == 0x06, p.count >= 0x30 {
        return ["type": "device", "name": text(p, 0x0c, 0x20), "number": Int(p[0x24]),
                "ip": p[0x2c..<0x30].map(String.init).joined(separator: ".")]
    }
    if port == BEAT_PORT, kind == 0x28, p.count >= 0x60 {
        let pitch = Double(u32(p, 0x54) - 0x100000) / Double(0x100000) * 100
        let bpm = Double(u16(p, 0x5a)) / 100
        var m: Message = ["type": "beat", "name": text(p, 0x0b, 0x1f), "number": Int(p[0x21]), "bpm": bpm]
        m["pitch"] = round2(pitch); m["tempo"] = round2(bpm * (1 + pitch / 100)); m["beat"] = Int(p[0x5c])
        m["nextBeatMs"] = u32(p, 0x24); m["nextBarMs"] = u32(p, 0x2c)
        return m
    }
    if port == STATUS_PORT, kind == 0x0a, p.count >= 0xd0 {
        let flags = p[0x89], bpm = u16(p, 0x92)
        let pitch = Double(u32(p, 0x8c) - 0x100000) / Double(0x100000) * 100
        var m: Message = ["type": "status", "name": text(p, 0x0b, 0x1f), "number": Int(p[0x21])]
        // The player's firmware version, as text such as "1.40".
        m["firmware"] = text(p, 0x7c, 0x80)
        m["source"] = Int(p[0x28]); m["slot"] = Int(p[0x29]); m["trackType"] = Int(p[0x2a])
        m["rekordboxId"] = u32(p, 0x2c); m["trackNumber"] = u16(p, 0x32)
        m["playing"] = flags & 0x40 != 0; m["master"] = flags & 0x20 != 0
        m["sync"] = flags & 0x10 != 0; m["onAir"] = flags & 0x08 != 0
        m["bpm"] = bpm == 0xffff ? NSNull() : Double(bpm) / 100
        m["pitch"] = round2(pitch)
        if let key = statusKey(p), bpm != 0xffff { m["key"] = key }
        return m
    }
    if port == BEAT_PORT, kind == 0x26 || kind == 0x27 {
        return ["type": "master", "kind": kind == 0x26 ? "request" : "response", "number": Int(p[0x21])]
    }
    return ["type": "other", "port": Int(port), "kind": Int(kind), "number": Int(p[0x21])]
}

func json(_ m: Message) -> Data { (try? JSONSerialization.data(withJSONObject: m, options: [.sortedKeys])) ?? Data("{}".utf8) }

// The announcement that we are a player, as beat-link sends it.
func announcement(number: UInt8, ip: [UInt8], mac: [UInt8]) -> [UInt8] {
    var name = Array("sequent".utf8); name += [UInt8](repeating: 0, count: 20 - name.count)
    var p: [UInt8] = MAGIC
    p += [0x06, 0x00]
    p += name
    p += [0x01, 0x02, 0x00, 0x36, number, 0x01]
    p += mac
    p += ip
    p += [0x01, 0x00, 0x00, 0x00, 0x01, 0x00]
    return p
}

// MARK: - Leading: Sequent as the tempo master

// When the page carries on after the decks stop, Sequent can lead them: it
// becomes a player (a real number, 1 to 4, which is what players accept a
// master from), sends status and beat packets like a playing, synced CDJ,
// and takes the tempo master role, so a deck with Sync on follows Sequent's
// tempo and beat. The layouts are Deep Symmetry's (vcdj, beats and sync
// notes); the byte templates are the ones their beat-link sends, as facts of
// the protocol.

// Every beat-port and status-port packet: the magic, its kind, our name.
func header(_ kind: UInt8) -> [UInt8] {
    var name = Array("sequent".utf8); name += [UInt8](repeating: 0, count: 20 - name.count)
    return MAGIC + [kind] + name
}
func put(_ p: inout [UInt8], _ at: Int, _ v: Int, _ size: Int) {
    for i in 0..<size { p[at + i] = UInt8(truncatingIfNeeded: v >> (8 * (size - 1 - i))) }
}

// A CDJ status packet (0x0a, 0x11c bytes), offsets as Deep Symmetry number
// them (from the start of the packet).
let STATUS_TEMPLATE: [UInt8] = [
    0x01, 0x04, 0x00, 0x00, 0xf8, 0x00, 0x00, 0x01, 0x00, 0x00, 0x03, 0x01, 0x00, 0x00, 0x00, 0x00,
    0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xa0, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x04, 0x04, 0x00, 0x00, 0x00,
    0x04, 0x00, 0x00, 0x00, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x31, 0x2e, 0x34,
    0x33, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0x00, 0x00, 0x10, 0x00,
    0x00, 0x80, 0x00, 0x00, 0x00, 0x7f, 0xff, 0xff, 0xff, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0f, 0x01, 0x00,
    0x00, 0x12, 0x34, 0x56, 0x78, 0x00, 0x00, 0x00, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x15, 0x00, 0x00, 0x07, 0x61, 0x00, 0x00, 0x06, 0x2f,
]
func statusPacket(number: UInt8, playing: Bool, master: Bool, synced: Bool, handoff: UInt8, tempo: Double, beat: Int, beatInBar: Int, sync: Int, counter: Int) -> [UInt8] {
    var p = header(0x0a) + STATUS_TEMPLATE
    p[0x21] = number; p[0x24] = number; p[0x28] = number   // D, and the player the track is from
    p[0x27] = playing ? 1 : 0
    p[0x7b] = playing ? 3 : 5                                // P1: playing or paused
    put(&p, 0x84, sync, 4)                                   // the sync counter
    p[0x89] = 0x84 | (playing ? 0x40 : 0) | (master ? 0x20 : 0) | (synced ? 0x10 : 0)
    p[0x8b] = playing ? 0x7a : 0x7e                          // P2
    put(&p, 0x92, Int((tempo * 100).rounded()), 2)           // the track's tempo; pitch stays at 0%
    p[0x9d] = playing ? 9 : 1                                // P3
    p[0x9e] = master ? 1 : 0                                 // Mm
    p[0x9f] = handoff                                        // Mh: 0xff, or the player master goes to
    put(&p, 0xa0, beat, 4)
    p[0xa6] = UInt8(beatInBar)
    put(&p, 0xc8, counter, 4)
    return p
}

// A beat packet (0x28, 0x60 bytes): the times to the next beats and bars at
// this tempo, the tempo, and the beat in the bar.
let BEAT_TEMPLATE: [UInt8] = [
    0x01, 0x00, 0x0d, 0x00, 0x3c, 0x01, 0x01, 0x01, 0x01, 0x02, 0x02, 0x02, 0x02, 0x10, 0x10, 0x10,
    0x10, 0x04, 0x04, 0x04, 0x04, 0x20, 0x20, 0x20, 0x20, 0x08, 0x08, 0x08, 0x08, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0b, 0x00, 0x00,
    0x0d,
]
func beatPacket(number: UInt8, tempo: Double, beatInBar: Int) -> [UInt8] {
    var p = header(0x28) + BEAT_TEMPLATE
    let beatMs = Int((60000 / tempo).rounded()), nextBar = beatMs * (5 - beatInBar)
    p[0x21] = number
    put(&p, 0x24, beatMs, 4); put(&p, 0x28, beatMs * 2, 4); put(&p, 0x2c, nextBar, 4)
    put(&p, 0x30, beatMs * 4, 4); put(&p, 0x34, nextBar + beatMs * 4, 4); put(&p, 0x38, beatMs * 8, 4)
    put(&p, 0x5a, Int((tempo * 100).rounded()), 2)
    p[0x5c] = UInt8(beatInBar)
    p[0x5f] = number
    return p
}

// A packet a phone passed on: "SQFW", version 1, the port (2 bytes), the
// deck's address (4), when the phone heard it (8, milliseconds since 1970),
// then the packet; nil for anything else. As SequentCore's Forward.encode.
func forwarded(_ d: [UInt8]) -> (port: UInt16, source: [UInt8], heardMs: Double, packet: [UInt8])? {
    guard d.count > 19, Array(d.prefix(4)) == Array("SQFW".utf8), d[4] == 1 else { return nil }
    let ms = d[11..<19].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    return (UInt16(d[5]) << 8 | UInt16(d[6]), Array(d[7..<11]), Double(ms), Array(d[19...]))
}

// Keeping a phone's clock and this Mac's together, NTP's way: a ping with
// our time (t1), the phone's answer with t1, when it got it (t2) and sent
// the answer (t3), and when that came (t4), all nanoseconds since 1970 on
// each one's own clock. The offset is the phone's clock less ours; the
// answer with the shortest round trip lately says it best. As SequentCore's
// Forward.ping, .pong and .sync.
func pingPacket(_ t1: UInt64) -> [UInt8] { Array("SQPI".utf8) + [1] + (0..<8).map { UInt8(truncatingIfNeeded: t1 >> (8 * (7 - $0))) } }
func pongTimes(_ d: [UInt8]) -> (t1: UInt64, t2: UInt64, t3: UInt64)? {
    guard d.count == 29, Array(d.prefix(4)) == Array("SQPO".utf8), d[4] == 1 else { return nil }
    let at = { (i: Int) in d[i..<i + 8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) } }
    return (at(5), at(13), at(21))
}
func clockSync(t1: UInt64, t2: UInt64, t3: UInt64, t4: UInt64) -> (offset: Int64, roundTrip: Int64) {
    let (a, b, c, d) = (Int64(bitPattern: t1), Int64(bitPattern: t2), Int64(bitPattern: t3), Int64(bitPattern: t4))
    return (((b - a) + (c - d)) / 2, (d - a) - (c - b))
}
func nowNs() -> UInt64 { UInt64(max(0, Date().timeIntervalSince1970 * 1e9)) }

// How a phone's packets travel, from each one's delay: when it arrived here
// less when the phone heard it, in milliseconds. That mixes the network with
// the two clocks' difference, but the smallest lately (the baseline) is the
// quickest the network goes plus that difference, and how far each lands
// behind it is the Wi-Fi's own delay, with no clock in it. Nil for none.
func hopStats(_ delays: [Double]) -> (base: Double, median: Double, p95: Double)? {
    guard let base = delays.min() else { return nil }
    let behind = delays.map { $0 - base }.sorted()
    let at = { (q: Double) in behind[min(behind.count - 1, Int((q * Double(behind.count - 1)).rounded()))] }
    return (base, at(0.5), at(0.95))
}

// Asking the master to hand over (0x26), and agreeing to hand over (0x27).
func handoffRequest(number: UInt8) -> [UInt8] { header(0x26) + [0x01, 0x00, number, 0x00, 0x04, 0x00, 0x00, 0x00, number] }
func handoffResponse(number: UInt8) -> [UInt8] { header(0x27) + [0x01, 0x00, number, 0x00, 0x08, 0x00, 0x00, 0x00, number, 0x00, 0x00, 0x00, 0x01] }

// What leading decides, apart from the sockets and timers, so it can be
// driven in a self-test: it is told what the page and the players say, and
// says what to send.
typealias Players = [Int: (ip: String, master: Bool, playing: Bool, synced: Bool)]
enum Out: Equatable {
    case announceAs(UInt8)                          // announce as this player
    case status([UInt8])                            // to every player, port 50002
    case beat([UInt8])                              // broadcast, port 50001
    case unicast([UInt8], ip: String, port: UInt16)
}
final class Leader {
    // The page's lead: playing, at what tempo, and the beat in the bar.
    private(set) var leading = false
    private(set) var number: UInt8? = nil           // our player number while we lead or hand over
    private(set) var master = false
    private var tempo = 120.0, beatInBar = 1, beat = 0
    private var next: UInt8 = 0xff                  // the player we are handing master to
    private var asked = 0                           // the player we asked for master
    private var sync = 1, largestSync = 0, counter = 0
    private var stoppedAt: Double? = nil
    private var heardAt = 0.0                       // when the page last said lead
    private var held = false                        // had master this time: a deck that takes it keeps it
    var out: (Out) -> Void = { _ in }

    // The page says lead, at this tempo, on this beat of the bar; `players`
    // are the decks seen lately with their statuses.
    func lead(playing: Bool, tempo: Double, beatInBar: Int, players: Players, now: Double) {
        if playing {
            heardAt = now
            if tempo > 0 { self.tempo = tempo }
            if (1...4).contains(beatInBar) { self.beatInBar = beatInBar }
            stoppedAt = nil
            if number == nil {
                // A real player number no deck is using, from the top down.
                guard let n = [4, 3, 2, 1].first(where: { players[$0] == nil }) else { return }
                number = UInt8(n)
                out(.announceAs(UInt8(n)))
            }
            // Playing again while handing over calls the handover off: the
            // role is ours to keep, not still offered to a deck.
            if !leading { leading = true; held = false; next = 0xff; claim(players, now: now, ask: false) }
        } else if leading {
            leading = false
            stoppedAt = now
            // Hand master to a deck that is playing in sync, else just let it go.
            if master, let n = players.filter({ $0.value.playing && $0.value.synced }).keys.sorted().first { next = UInt8(n) }
            else { master = false }
        }
    }

    // Take the master role: at once if nobody has it, else ask the master,
    // and again every two seconds until it hands over. A deck ignores a
    // request from a player it hasn't yet had status from (seen with a
    // CDJ-3000X on 17 October 2026), so the first is asked only once our
    // status has been going for a little while; a stopped master often hands
    // over unasked by then anyway.
    private var claimedAt = 0.0
    private func claim(_ players: Players, now: Double, ask: Bool = true) {
        guard let number, !master else { return }
        guard let (n, p) = players.first(where: { $0.value.master && $0.key != Int(number) }) else { master = true; asked = 0; return }
        guard ask else { claimedAt = now - 1.6; return }
        claimedAt = now
        asked = n
        out(.unicast(handoffRequest(number: number), ip: p.ip, port: BEAT_PORT))
    }

    // A beat of ours, as the page plays it.
    func beatNow(beatInBar: Int) {
        guard leading, let number else { return }
        self.beatInBar = beatInBar
        beat += 1
        out(.beat(beatPacket(number: number, tempo: tempo, beatInBar: beatInBar)))
    }

    // Our status, five times a second while leading or handing over; the
    // role is given up a second after the page stops, if nobody took it.
    func tick(now: Double, players: Players) {
        guard let number else { return }
        // A page that has gone quiet (closed, or asleep) stops leading.
        if leading, now - heardAt > 2 { lead(playing: false, tempo: 0, beatInBar: beatInBar, players: players, now: now) }
        // Asked again until we've had it; once a deck has taken it from us
        // (its MASTER button), it's the DJ's choice, and not fought over.
        if leading, !master, !held, now - claimedAt > 2 { claim(players, now: now) }
        if master { held = true }
        if !leading, let at = stoppedAt, now - at > 1, next == 0xff || now - at > 4 {
            stoppedAt = nil; next = 0xff; asked = 0
            // Still master, as the deck it was offered to never took it: say
            // we aren't before going, as on quitting.
            if master { leave(); return }
            self.number = nil
            out(.announceAs(VIRTUAL_PLAYER))
            return
        }
        counter += 1
        out(.status(statusPacket(number: number, playing: leading, master: master, synced: true, handoff: next, tempo: tempo, beat: beat, beatInBar: beatInBar, sync: sync, counter: counter)))
    }

    // A player's status packet: its sync counter, and whether it hands master
    // to us, or has taken it.
    func status(_ p: [UInt8]) {
        guard p.count >= 0xa0, let number, Int(p[0x21]) != Int(number) else { return }
        let from = p[0x21], isMaster = p[0x89] & 0x20 != 0, yieldingTo = p[0x9f]
        largestSync = max(largestSync, u32(p, 0x84))
        guard isMaster else { return }
        if yieldingTo == number {
            if leading { master = true; held = true; asked = 0 }
        } else if yieldingTo == 0xff, master {
            // Another player asserting master: handed over as we said, or taken.
            if from == next { sync = largestSync + 1 }
            master = false; next = 0xff
        }
    }

    // Quitting while we lead: a last status saying we've stopped and aren't
    // master, so no deck is left with a master that vanished. (A copy that
    // quit as master on 17 October 2026 left the CDJ-3000X sending its
    // status to nobody until it was replugged.)
    func leave() {
        guard let number else { return }
        counter += 1
        let last = statusPacket(number: number, playing: false, master: false, synced: false, handoff: 0xff, tempo: tempo, beat: beat, beatInBar: beatInBar, sync: sync, counter: counter)
        out(.status(last)); out(.status(last))
        leading = false; master = false; self.number = nil
        out(.announceAs(VIRTUAL_PLAYER))
    }

    // A player asking us for master: agree, and name it as the next master.
    func requested(by player: Int, ip: String) {
        guard master, let number, player != Int(number) else { return }
        next = UInt8(player)
        // To the beat port, as Deep Symmetry's notes say, and the status
        // port, where beat-link sends it; agreeing twice changes nothing.
        out(.unicast(handoffResponse(number: number), ip: ip, port: BEAT_PORT))
        out(.unicast(handoffResponse(number: number), ip: ip, port: STATUS_PORT))
    }
}

// MARK: - The links: our address and MAC on each link-local interface

struct Link { let name: String; let ip: [UInt8]; let mac: [UInt8] }

func links() -> [Link] {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
    defer { freeifaddrs(ifaddr) }
    var ips: [String: [UInt8]] = [:], macs: [String: [UInt8]] = [:]
    for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let name = String(cString: p.pointee.ifa_name)
        guard let sa = p.pointee.ifa_addr else { continue }
        if sa.pointee.sa_family == UInt8(AF_INET) {
            let a = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let b = withUnsafeBytes(of: a) { Array($0) }
            if b[0] == 169 && b[1] == 254 { ips[name] = b }
        } else if sa.pointee.sa_family == UInt8(AF_LINK) {
            let dl = sa.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { $0.pointee }
            if dl.sdl_alen == 6 {
                // The address follows the interface's name in sdl_data, and can
                // run past the struct's declared twelve bytes, so it is read
                // from the system's own memory rather than a copy.
                let start = UnsafeRawPointer(sa) + MemoryLayout<sockaddr_dl>.offset(of: \sockaddr_dl.sdl_data)! + Int(dl.sdl_nlen)
                macs[name] = (0..<6).map { start.load(fromByteOffset: $0, as: UInt8.self) }
            }
        }
    }
    return ips.compactMap { name, ip in macs[name].map { Link(name: name, ip: ip, mac: $0) } }.sorted { $0.name < $1.name }
}

// MARK: - The deck's database: a rekordbox track's title, artist and key

enum Field { case number(Int), blob([UInt8]), string(String) }

func number(_ n: Int, _ size: Int = 4) -> [UInt8] {
    let tag: UInt8 = size == 1 ? 0x0f : size == 2 ? 0x10 : 0x11
    return [tag] + (0..<size).map { UInt8(truncatingIfNeeded: n >> (8 * (size - 1 - $0))) }
}
let DB_MAGIC = 0x872349ae, DB_SETUP_TX = 0xfffffffe
func dbMessage(tx: Int, kind: Int, args: [Int]) -> [UInt8] {
    var tags = [UInt8](repeating: 0x06, count: args.count); tags += [UInt8](repeating: 0, count: 12 - tags.count)
    var m: [UInt8] = number(DB_MAGIC)
    m += number(tx)
    m += number(kind, 2)
    m += number(args.count, 1)
    m += [0x14, 0, 0, 0, 12]
    m += tags
    for a in args { m += number(a) }
    return m
}

final class Socket {
    let fd: Int32
    init?(ip: String, port: UInt16, local: [UInt8]?, timeout: Int = 3) {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        if let local {
            var la = sockaddr_in(); la.sin_family = sa_family_t(AF_INET); la.sin_port = 0
            la.sin_addr.s_addr = local.withUnsafeBytes { $0.load(as: UInt32.self) }
            _ = withUnsafePointer(to: &la) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
        var ra = sockaddr_in(); ra.sin_family = sa_family_t(AF_INET); ra.sin_port = port.bigEndian
        inet_pton(AF_INET, ip, &ra.sin_addr)
        let ok = withUnsafePointer(to: &ra) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if ok != 0 { close(fd); return nil }
    }
    deinit { close(fd) }
    func send(_ b: [UInt8]) -> Bool { b.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, b.count, 0) } == b.count }
    func read(_ n: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: n), got = 0
        while got < n {
            let r = out.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + got, n - got, 0) }
            if r <= 0 { throw NSError(domain: "db", code: 1) }
            got += r
        }
        return out
    }
    func field() throws -> Field {
        let tag = try read(1)[0]
        switch tag {
        case 0x0f, 0x10, 0x11:
            let b = try read(tag == 0x0f ? 1 : tag == 0x10 ? 2 : 4)
            return .number(b.reduce(0) { $0 << 8 | Int($1) })
        case 0x14:
            let n = try read(4).reduce(0) { $0 << 8 | Int($1) }
            return .blob(n > 0 ? try read(n) : [])
        case 0x26:
            let n = try read(4).reduce(0) { $0 << 8 | Int($1) }
            let b = try read(n * 2)
            let units = stride(from: 0, to: b.count, by: 2).map { UInt16(b[$0]) << 8 | UInt16(b[$0 + 1]) }
            return .string(String(decoding: units, as: UTF16.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0")))
        default: throw NSError(domain: "db", code: 2)
        }
    }
    func response() throws -> (Int, [Field]) {
        guard case .number(DB_MAGIC) = try field() else { throw NSError(domain: "db", code: 3) }
        _ = try field()
        guard case let .number(kind) = try field(), case let .number(count) = try field() else { throw NSError(domain: "db", code: 4) }
        _ = try field()
        return (kind, try (0..<count).map { _ in try field() })
    }
}

// Posing as a real player number, 1 to 4, which players answer.
func metadata(ip: String, slot: Int, id: Int, posing: Int, local: [UInt8]?) -> [String: String]? {
    guard let q = Socket(ip: ip, port: DB_PORT, local: local), q.send([0, 0, 0, 0x0f] + Array("RemoteDBServer".utf8) + [0]),
          let pb = try? q.read(2) else { return nil }
    let port = UInt16(pb[0]) << 8 | UInt16(pb[1])
    guard let s = Socket(ip: ip, port: port, local: local) else { return nil }
    do {
        guard s.send(number(1)) else { return nil }
        _ = try s.read(5)
        guard s.send(dbMessage(tx: DB_SETUP_TX, kind: 0x0000, args: [posing])) else { return nil }
        _ = try s.response()
        let dmst = posing << 24 | 1 << 16 | slot << 8 | 1
        guard s.send(dbMessage(tx: 1, kind: 0x2002, args: [dmst, id])) else { return nil }
        let (_, args) = try s.response()
        var count = 0
        if args.count > 1, case let .number(n) = args[1] { count = n }
        guard s.send(dbMessage(tx: 2, kind: 0x3000, args: [dmst, 0, count, 0, count, 0])) else { return nil }
        var found: [String: String] = [:]
        let labels = [0x04: "title", 0x07: "artist", 0x02: "album", 0x0f: "key"]
        while true {
            let (kind, args) = try s.response()
            if kind == 0x4101, args.count > 6, case let .number(t) = args[6], let label = labels[t & 0xff], case let .string(v) = args[3], !v.isEmpty { found[label] = v }
            if kind != 0x4101 && kind != 0x4001 { break }
        }
        _ = s.send(dbMessage(tx: DB_SETUP_TX, kind: 0x0100, args: []))
        return found
    } catch { return nil }
}

// MARK: - The helper: UDP in, WebSocket out

final class Helper {
    var devices: [Int: Message] = [:]
    var announced: [Int: Double] = [:]
    var statuses: [Int: (Message, Double)] = [:]
    var tracks: [String: [String: String]] = [:]
    var seen: [Data: Double] = [:]
    var sockets: [UInt16: (Int32, DispatchSourceRead)] = [:]
    var blocked = false
    var linkList: [Link] = []
    var senders: [(Int32, [UInt8])] = []
    var clients: [ObjectIdentifier: NWConnection] = [:]
    var listener: NWListener?
    var onChange: () -> Void = {}
    var onBeat: () -> Void = {}
    var beats: [Int: (tempo: Double, at: Double)] = [:]   // each deck's last beat
    // Leading the decks when the page asks (Leader, above): the player number
    // we announce as, the timer for our status, and what the page last heard
    // about it.
    let leader = Leader()
    var playerNumber = VIRTUAL_PLAYER
    var leadTimer: DispatchSourceTimer?
    var told: (UInt8?, Bool) = (nil, false)
    let listenOnly = CommandLine.arguments.contains("--listen-only")
    // `--capture DIR`: keep each deck's raw status packet whenever the bytes
    // that should name its track change, for working out a layout we don't
    // know yet (the CDJ-3000X's 1152-byte status reports the documented
    // source, slot and rekordbox ID as zero). Load tracks one at a time and
    // note what each was; every save is also listed on standard output.
    let captureDir: String? = CommandLine.arguments.drop(while: { $0 != "--capture" }).dropFirst().first
    var captured: [Int: [UInt8]] = [:]

    func capture(_ packet: [UInt8]) {
        guard let dir = captureDir, packet.count > 0x1b0, packet[0x0a] == 0x0a else { return }
        let deck = Int(packet[0x21])
        // Where the documented identity lives, the key (0x150–0x15f),
        // and the stretch further on where it repeats the identity.
        let window = Array(packet[0x24..<0x48]) + Array(packet[0x150..<0x160]) + Array(packet[0x180..<0x1b0])
        guard captured[deck] != window else { return }
        captured[deck] = window
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let name = "\(Int(Date().timeIntervalSince1970 * 1000))-deck\(deck).bin"
        FileManager.default.createFile(atPath: (dir as NSString).appendingPathComponent(name), contents: Data(packet))
        let hex = { (r: Range<Int>) in packet[r].map { String(format: "%02x", $0) }.joined(separator: " ") }
        print("\(name)  0x24: \(hex(0x24..<0x48))  0x150: \(hex(0x150..<0x160))  0x18c: \(hex(0x18c..<0x1b0))")
        fflush(stdout)
    }

    func start() {
        leader.out = { [weak self] o in self?.emit(o) }
        bindPorts()
        serve()
        listenForPhones()
        // Retry the ports while something else holds them, look for new links,
        // and announce, on a timer.
        // Tolerance lets macOS fold these wake-ups in with others.
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.blocked { self.bindPorts() }
            self.announce()
        }.tolerance = 0.2
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.refreshLinks() }.tolerance = 2
        refreshLinks()
    }

    // Packets passed on by a phone on the decks' link (the iPhone app's
    // Forwarder): Bonjour advertises `_sequent._udp`, and each datagram is
    // one packet with a header saying the port it came to, the deck it came
    // from and when (the format is in turpin-studio/sequent-apple,
    // SequentCore/Forward.swift). They're handled as the decks' own, so the
    // page follows decks this Mac isn't wired to. Leading needs the decks to
    // hear this Mac, so it doesn't reach them this way.
    var forwardListener: NWListener?
    var forwardedCount = 0
    // The delays of the last ten seconds' packets (arrival less heard), and
    // what they say: shown in the menu, logged, and told to the page.
    var hops: [(at: Double, delay: Double)] = []
    var hopSummary: (base: Double, median: Double, p95: Double)?
    var hopsTold = 0.0
    // Stamping a forwarded packet when the phone heard it, plus the
    // baseline, takes the Wi-Fi's uneven delay out of the beats' timing;
    // SEQUENT_RAW_FORWARD=1 stamps them on arrival instead, to compare.
    let correctForwarded = ProcessInfo.processInfo.environment["SEQUENT_RAW_FORWARD"] == nil
    // Each phone's clock, from its answers to our pings: the round trips and
    // offsets of the last thirty seconds, and a ping every half second.
    var syncs: [ObjectIdentifier: [(at: Double, roundTrip: Int64, offset: Int64)]] = [:]
    var pingTimers: [ObjectIdentifier: DispatchSourceTimer] = [:]
    var bestSync: (roundTrip: Int64, offset: Int64)?
    func best(_ id: ObjectIdentifier) -> (roundTrip: Int64, offset: Int64)? {
        syncs[id]?.min { $0.roundTrip < $1.roundTrip }.map { ($0.roundTrip, $0.offset) }
    }
    func listenForPhones() {
        let l: NWListener
        do { l = try NWListener(using: .udp) }
        catch { FileHandle.standardError.write(Data("Sequent: can't listen for phones: \(error)\n".utf8)); return }
        l.service = NWListener.Service(name: Host.current().localizedName ?? "Sequent", type: "_sequent._udp")
        l.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            c.start(queue: .main)
            let id = ObjectIdentifier(c)
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(deadline: .now(), repeating: .milliseconds(500), leeway: .milliseconds(5))
            t.setEventHandler { c.send(content: Data(pingPacket(nowNs())), completion: .idempotent) }
            t.resume()
            self.pingTimers[id] = t
            c.stateUpdateHandler = { [weak self] state in
                if case .cancelled = state { self?.pingTimers[id]?.cancel(); self?.pingTimers[id] = nil; self?.syncs[id] = nil }
                if case .failed = state { self?.pingTimers[id]?.cancel(); self?.pingTimers[id] = nil; self?.syncs[id] = nil }
            }
            self.readForwarded(c)
        }
        l.stateUpdateHandler = { state in FileHandle.standardError.write(Data("Sequent: listening for phones (_sequent._udp) \(state)\n".utf8)) }
        l.start(queue: .main)
        forwardListener = l
    }
    func readForwarded(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            let got = nowNs()
            guard let self, error == nil else { c.cancel(); return }
            let id = ObjectIdentifier(c)
            if let data, let (t1, t2, t3) = pongTimes(Array(data)) {
                let s = clockSync(t1: t1, t2: t2, t3: t3, t4: got)
                var list = self.syncs[id, default: []]
                list.append((Double(got) / 1e9, s.roundTrip, s.offset))
                list.removeAll { Double(got) / 1e9 - $0.at > 30 }
                self.syncs[id] = list
                self.bestSync = self.best(id)
            }
            if let data, let (port, source, heard, packet) = forwarded(Array(data)),
               Date().timeIntervalSince1970 - (self.direct[source] ?? 0) > 3 {
                self.forwardedCount += 1
                let arrived = Date().timeIntervalSince1970 * 1000
                self.hops.append((arrived, arrived - heard))
                self.hops.removeAll { arrived - $0.at > 10_000 }
                // With the phone's clock known, when it heard the packet is
                // exactly that moment on ours; without (a phone that doesn't
                // answer pings), the quickest packet lately stands in.
                let base = self.hops.map(\.delay).min() ?? 0
                let mine = self.best(id).map { heard - Double($0.offset) / 1e6 } ?? heard + base
                self.handle(packet, port: port, source: source, at: self.correctForwarded ? mine / 1000 : nil)
                if arrived - self.hopsTold > 2000 { self.hopsTold = arrived; self.tellHops() }
            }
            self.readForwarded(c)
        }
    }

    // Every couple of seconds: the figures to the menu, the log and the page.
    func tellHops() {
        guard let h = hopStats(hops.map(\.delay)) else { return }
        hopSummary = h
        var line = String(format: "via iPhone over Wi-Fi: Wi-Fi delay %.0f ms typical, %.0f ms at worst (95%%), baseline %.0f ms", h.median, h.p95, h.base)
        if let b = bestSync { line += String(format: "; clocks synced, one way %.1f ms, phone %+.1f ms", Double(b.roundTrip) / 2e6, Double(b.offset) / 1e6) }
        FileHandle.standardError.write(Data("Sequent: \(line)\(correctForwarded ? "" : " (not corrected)")\n".utf8))
        broadcast(["type": "forwarding", "baseMs": (h.base * 10).rounded() / 10, "medianMs": (h.median * 10).rounded() / 10,
                   "p95Ms": (h.p95 * 10).rounded() / 10, "packets": forwardedCount, "corrected": correctForwarded,
                   "oneWayMs": bestSync.map { (Double($0.roundTrip) / 2e5).rounded() / 10 } ?? NSNull(),
                   "clockOffsetMs": bestSync.map { (Double($0.offset) / 1e5).rounded() / 10 } ?? NSNull()])
        onChange()
    }

    func bindPorts() {
        let ports = listenOnly ? [ANNOUNCE_PORT, BEAT_PORT] : [ANNOUNCE_PORT, BEAT_PORT, STATUS_PORT]
        var failed = false
        for port in ports where sockets[port] == nil {
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, 4)
            var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_port = port.bigEndian; a.sin_addr.s_addr = INADDR_ANY
            let ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            if ok != 0 { close(fd); failed = true; continue }
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            src.setEventHandler { [weak self] in self?.receive(fd: fd, port: port) }
            src.resume()
            sockets[port] = (fd, src)
        }
        if blocked != failed { blocked = failed; onChange() }
    }

    func refreshLinks() {
        let now = links()
        guard now.map(\.name) != linkList.map(\.name) || now.map(\.ip) != linkList.map(\.ip) else { return }
        for (fd, _) in senders { close(fd) }
        senders = now.compactMap { link in
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, 4)
            var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET)
            a.sin_addr.s_addr = link.ip.withUnsafeBytes { $0.load(as: UInt32.self) }
            let ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            if ok != 0 { close(fd); return nil }
            return (fd, announcement(number: playerNumber, ip: link.ip, mac: link.mac))
        }
        let could = canLead
        linkList = now
        if canLead != could { broadcast(["type": "links", "canLead": canLead]) }
        onChange()
    }

    // Say we are here on every link, so the players send us their status.
    func announce() {
        guard !listenOnly else { return }
        var to = sockaddr_in(); to.sin_family = sa_family_t(AF_INET); to.sin_port = ANNOUNCE_PORT.bigEndian
        inet_pton(AF_INET, "169.254.255.255", &to.sin_addr)
        for (fd, packet) in senders {
            _ = packet.withUnsafeBytes { p in withUnsafePointer(to: &to) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, p.baseAddress, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } }
        }
    }

    func receive(fd: Int32, port: UInt16) {
        var buf = [UInt8](repeating: 0, count: 2048)
        var from = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &from) { f in f.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) } }
        guard n > 0 else { return }
        let source = withUnsafeBytes(of: from.sin_addr.s_addr) { Array($0) }
        direct[source] = Date().timeIntervalSince1970
        handle(Array(buf[0..<n]), port: port, source: source)
    }
    // When each deck was last heard on this Mac's own links: one heard
    // directly isn't taken from a phone too (forwarded copies arrive too late
    // to be dropped as copies, and would double its beats).
    var direct: [[UInt8]: Double] = [:]

    // A packet from a deck: off the decks' own link, or passed on by a phone
    // on it (forwarded(), below), with the deck's address either way.
    func handle(_ packet: [UInt8], port: UInt16, source: [UInt8], at: Double? = nil) {
        let now = at ?? Date().timeIntervalSince1970
        // Our own announcements, status and beats come back to us: not a deck.
        if linkList.contains(where: { $0.ip == source }) { return }
        // Each packet arrives once per USB link: drop the copy seen moments ago.
        let key = Data(packet)
        seen = seen.filter { now - $0.value < 0.05 }
        if seen[key] != nil { return }
        seen[key] = now
        if port == STATUS_PORT { capture(packet) }
        if port == STATUS_PORT, packet.count > 0x0a, packet[0x0a] == 0x0a { leader.status(packet); tellPage() }
        if port == BEAT_PORT, packet.count >= 0x28, packet[0x0a] == 0x26 {
            leader.requested(by: Int(packet[0x21]), ip: source.map(String.init).joined(separator: "."))
            tellPage()
        }
        guard var msg = parse(port: port, packet) else { return }
        msg["t"] = Int((now * 1000).rounded())
        msg["from"] = source.map(String.init).joined(separator: ".")
        let number = msg["number"] as? Int ?? 0
        if msg["type"] as? String == "device" {
            let known = devices[number]
            devices[number] = msg
            if let known, known["name"] as? String == msg["name"] as? String, now - (announced[number] ?? 0) < 4 { return }
            announced[number] = now
            onChange()
        }
        if msg["type"] as? String == "status" { guard statusChanged(&msg, now) else { return } }
        if msg["type"] as? String == "beat", let tempo = msg["tempo"] as? Double { beats[number] = (tempo, now); onBeat() }
        broadcast(msg)
    }

    // Status arrives several times a second: pass on changes, and otherwise
    // one a second; and look up a rekordbox track's details once.
    func statusChanged(_ msg: inout Message, _ now: Double) -> Bool {
        let number = msg["number"] as? Int ?? 0
        if let rid = msg["rekordboxId"] as? Int, rid != 0, msg["trackType"] as? Int == 1 {
            let key = "\(msg["source"] ?? 0)/\(msg["slot"] ?? 0)/\(rid)"
            if let found = tracks[key] { for (k, v) in found where k != "key" || msg["key"] == nil { msg[k] = v } }
            else { tracks[key] = [:]; lookUp(key: key, msg: msg) }
        }
        let strip: (Message) -> NSDictionary = { m in var c = m; c["t"] = nil; c["from"] = nil; return c as NSDictionary }
        if let (sent, when) = statuses[number], strip(sent).isEqual(to: strip(msg) as! [AnyHashable: Any]), now - when < 1 { return false }
        let changed = statuses[number].map { !strip($0.0).isEqual(to: strip(msg) as! [AnyHashable: Any]) } ?? true
        statuses[number] = (msg, now)
        if changed { onChange() }
        return true
    }

    func lookUp(key: String, msg: Message) {
        guard let source = msg["source"] as? Int, let slot = msg["slot"] as? Int, let rid = msg["rekordboxId"] as? Int,
              let ip = devices[source]?["ip"] as? String else { return }
        let posing = devices.keys.sorted().first { (1...4).contains($0) && $0 != source } ?? [1, 2, 3, 4].first { $0 != source }!
        let locals = linkList.map(\.ip)
        DispatchQueue.global().async {
            var found: [String: String]? = nil
            for local in locals.isEmpty ? [nil] : locals.map(Optional.some) {
                found = metadata(ip: ip, slot: slot, id: rid, posing: posing, local: local)
                if found != nil { break }
            }
            DispatchQueue.main.async {
                self.tracks[key] = found ?? [:]
                for (number, (sent, _)) in self.statuses where "\(sent["source"] ?? 0)/\(sent["slot"] ?? 0)/\(sent["rekordboxId"] ?? 0)" == key {
                    var m = sent
                    for (k, v) in found ?? [:] where k != "key" || m["key"] == nil { m[k] = v }
                    m["t"] = Int((Date().timeIntervalSince1970 * 1000).rounded())
                    self.statuses[number] = (m, Date().timeIntervalSince1970)
                    self.broadcast(m)
                }
                self.onChange()
            }
        }
    }

    // MARK: WebSocket

    func serve() {
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        // Only pages from turpin.studio and this computer may connect.
        ws.setClientRequestHandler(.main) { _, headers in
            let origin = headers.first { $0.name.lowercased() == "origin" }?.value ?? ""
            return NWProtocolWebSocket.Response(status: allowed(origin) ? .accept : .reject, subprotocol: nil, additionalHeaders: nil)
        }
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        // This computer only: bound to 127.0.0.1.
        params.requiredInterfaceType = .loopback
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: WS_PORT)!)
        let l: NWListener
        do { l = try NWListener(using: params) }
        catch { FileHandle.standardError.write(Data("Sequent: can't listen on \(WS_PORT): \(error)\n".utf8)); return }
        l.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            let id = ObjectIdentifier(c)
            c.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    self.clients[id] = c
                    // Its version too, so the page can say when a newer one is out.
                    self.send(c, ["type": "hello", "version": APP_VERSION, "devices": Array(self.devices.values), "statuses": self.statuses.values.map(\.0), "canLead": self.canLead])
                    self.onChange()
                case .failed, .cancelled:
                    self.clients[id] = nil
                    self.onChange()
                default: break
                }
            }
            c.start(queue: .main)
            self.drain(c)
        }
        // Its state goes to the log (Console, or the terminal it was run from).
        l.stateUpdateHandler = { state in FileHandle.standardError.write(Data("Sequent: WebSocket on 127.0.0.1:\(WS_PORT) \(state)\n".utf8)) }
        l.start(queue: .main)
        listener = l
    }

    // The page says one thing, `lead`, while it carries on after the decks
    // stop; otherwise reading just notices it leave.
    func drain(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            if error != nil { c.cancel(); return }
            if let data, let m = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], m["type"] as? String == "lead" { self?.lead(m) }
            self?.drain(c)
        }
    }

    // MARK: Leading

    // The decks seen lately, with what their status says.
    var playerStates: Players {
        var out: Players = [:]
        for d in players {
            guard let n = d["number"] as? Int, let ip = d["ip"] as? String else { continue }
            let s = statuses[n]?.0
            out[n] = (ip, s?["master"] as? Bool == true, s?["playing"] as? Bool == true, s?["sync"] as? Bool == true)
        }
        return out
    }

    // { type: "lead", playing, tempo, beat (in the bar), beatAt (ms since
    // 1970, when the page's beat is heard) }: each beat while the page
    // carries on, and playing false when it stops. The beat packet goes out
    // as that beat is heard.
    // Leading needs a link of this Mac's own to the decks: they must hear its
    // announcement, status and beats. Hearing them only through a phone (over
    // Wi-Fi) isn't enough, as nothing goes back that way.
    var canLead: Bool { !linkList.isEmpty }

    func lead(_ m: [String: Any]) {
        guard !listenOnly else { return }
        let playing = m["playing"] as? Bool == true, tempo = m["tempo"] as? Double ?? 0
        if playing, !canLead, leader.number == nil {
            // Asked to lead with no way to: say why, rather than asking the
            // decks for master into nothing.
            broadcast(["type": "leading", "master": false, "number": NSNull(), "canLead": false, "t": Int((Date().timeIntervalSince1970 * 1000).rounded())])
            return
        }
        let beat = m["beat"] as? Int ?? 1, now = Date().timeIntervalSince1970
        leader.lead(playing: playing, tempo: tempo, beatInBar: beat, players: playerStates, now: now)
        if playing, let at = m["beatAt"] as? Double {
            let wait = at / 1000 - now
            // A timer of its own with a millisecond's leeway: the main queue's
            // own delays let it slip by several.
            if wait > -0.05 {
                let t = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
                t.schedule(deadline: .now() + max(0, wait), leeway: .milliseconds(1))
                t.setEventHandler { [weak self] in self?.leader.beatNow(beatInBar: beat); t.cancel() }
                t.resume()
            }
        }
        // A dispatch timer, not a run-loop one: scheduled from this callback,
        // a Timer wasn't noticed until the run loop next woke, and our status
        // started three seconds late (17 October 2026, on the rig).
        if leader.number != nil, leadTimer == nil {
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(deadline: .now(), repeating: .milliseconds(200), leeway: .milliseconds(5))
            t.setEventHandler { [weak self] in
                guard let self else { return }
                self.leader.tick(now: Date().timeIntervalSince1970, players: self.playerStates)
                if self.leader.number == nil { self.leadTimer?.cancel(); self.leadTimer = nil }
                self.tellPage()
            }
            t.resume()
            leadTimer = t
        }
        tellPage()
    }

    // What leading needs sent.
    func emit(_ o: Out) {
        switch o {
        case let .announceAs(n):
            playerNumber = n
            linkList = []   // rebuild the announcements with the new number
            refreshLinks()
            announce()
        case let .status(p): for d in playerStates.values { sendTo(p, ip: d.ip, port: STATUS_PORT) }
        case let .beat(p): sendTo(p, ip: "169.254.255.255", port: BEAT_PORT)
        case let .unicast(p, ip, port): sendTo(p, ip: ip, port: port)
        }
    }
    // Out of every link: a deck is on one of them.
    func sendTo(_ packet: [UInt8], ip: String, port: UInt16) {
        var to = sockaddr_in(); to.sin_family = sa_family_t(AF_INET); to.sin_port = port.bigEndian
        inet_pton(AF_INET, ip, &to.sin_addr)
        for (fd, _) in senders {
            _ = packet.withUnsafeBytes { p in withUnsafePointer(to: &to) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, p.baseAddress, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } }
        }
    }
    // The page told when leading starts, gets the master role, or ends.
    func tellPage() {
        let now = (leader.number, leader.master)
        guard now != told else { return }
        told = now
        var m: Message = ["type": "leading", "master": leader.master, "canLead": canLead, "t": Int((Date().timeIntervalSince1970 * 1000).rounded())]
        m["number"] = leader.number.map { Int($0) } ?? NSNull()
        broadcast(m)
        onChange()
    }

    func send(_ c: NWConnection, _ m: Message) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        c.send(content: json(m), contentContext: NWConnection.ContentContext(identifier: "message", metadata: [meta]), isComplete: true, completion: .idempotent)
    }
    func broadcast(_ m: Message) { for c in clients.values { send(c, m) } }

    // MARK: For the menu

    // The tempo to show: the master deck's while it beats, else any deck
    // beating; none once the decks have been quiet for two seconds.
    var tempo: Double? {
        let now = Date().timeIntervalSince1970
        let live = beats.filter { now - $0.value.at < 2 }
        let master = statuses.first { $0.value.0["master"] as? Bool == true }?.key
        if let m = master, let b = live[m] { return b.tempo }
        return live.sorted { $0.key < $1.key }.first?.value.tempo
    }

    var players: [Message] {
        let now = Date().timeIntervalSince1970
        return devices.values.filter { ($0["number"] as? Int ?? 0) <= 6 && now - (Double($0["t"] as? Int ?? 0) / 1000) < 10 }
            .sorted { ($0["number"] as? Int ?? 0) < ($1["number"] as? Int ?? 0) }
    }
    func line(for d: Message) -> String {
        let n = d["number"] as? Int ?? 0
        var parts = ["Deck \(n)"]
        if let (s, _) = statuses[n] {
            if let bpm = s["bpm"] as? Double { parts.append(String(format: "%.2f BPM", bpm * (1 + (s["pitch"] as? Double ?? 0) / 100))) }
            parts.append(s["playing"] as? Bool == true ? "playing" : "stopped")
            if s["master"] as? Bool == true { parts.append("master") }
            if let title = s["title"] as? String { parts.append(title + ((s["artist"] as? String).map { " — \($0)" } ?? "")) }
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - The menu-bar app

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let helper = Helper()
    var item: NSStatusItem!
    // A newer release than this one, once the site has said so.
    var update: String?
    // What the menu bar shows now, so it is only touched when that changes.
    var shownSymbol: String?, shownTitle: String?, shownTip: String?
    // Ticks once a second only while there's a tempo or a deck to age out;
    // idle, nothing changes without a packet or a link appearing.
    var ticker: Timer?
    // Whether rekordbox was running when the ports were last found taken:
    // asked once then, not on every refresh.
    var rekordbox = false

    // Quitting while leading hands the role back first.
    func applicationWillTerminate(_ n: Notification) { helper.leader.leave() }

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu(); menu.delegate = self; item.menu = menu
        helper.onChange = { [weak self] in self?.refreshIcon() }
        helper.onBeat = { [weak self] in self?.refreshIcon() }
        item.button?.imagePosition = .imageLeft
        item.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        helper.start()
        refreshIcon()
        // At launch and twice a day, since it may run for weeks at a time.
        checkForUpdate()
        Timer.scheduledTimer(withTimeInterval: 12 * 3600, repeats: true) { [weak self] _ in self?.checkForUpdate() }
    }

    // Asks the site which release is the latest: a plain request for a small
    // file, sending nothing about the decks or the person. A build that isn't
    // a release (0.0.0) never asks, and any failure is simply tried again later.
    func checkForUpdate() {
        guard APP_VERSION != "0.0.0" else { return }
        var request = URLRequest(url: LATEST); request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data, let latest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let version = latest["version"] as? String, newer(version, than: APP_VERSION) else { return }
            DispatchQueue.main.async {
                if self.update != version { FileHandle.standardError.write(Data("Sequent: \(version) is out, this is \(APP_VERSION)\n".utf8)) }
                self.update = version
                self.refreshIcon()
            }
        }.resume()
    }

    // Called on every beat and change, so it touches the menu bar only when
    // what it shows has changed: setting the image redraws it, even the same.
    func refreshIcon() {
        if helper.blocked && shownSymbol != "exclamationmark.triangle" { rekordbox = rekordboxRunning() }
        let found = !helper.players.isEmpty
        let symbol = helper.blocked ? "exclamationmark.triangle" : found ? "dot.radiowaves.left.and.right" : "waveform"
        if symbol != shownSymbol {
            item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Sequent")
            shownSymbol = symbol
        }
        // The tempo beside the icon while a deck plays.
        let tempo = helper.tempo
        let title = tempo.map { String(format: " %.1f", $0) } ?? ""
        if title != shownTitle {
            item.button?.title = title
            shownTitle = title
            FileHandle.standardError.write(Data("Sequent: tempo shown \(title.isEmpty ? "none" : title.trimmingCharacters(in: .whitespaces))\n".utf8))
        }
        let tip = status() + (update.map { "\nSequent \($0) is out" } ?? "")
        if tip != shownTip { item.button?.toolTip = tip; shownTip = tip }
        // Clears the tempo once the decks stop, and the icon once they go.
        let busy = tempo != nil || found
        if busy && ticker == nil {
            ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshIcon() }
            ticker?.tolerance = 0.2
        } else if !busy, let t = ticker { t.invalidate(); ticker = nil }
    }

    func rekordboxRunning() -> Bool { NSWorkspace.shared.runningApplications.contains { ($0.localizedName ?? "").lowercased().contains("rekordbox") } }

    func status() -> String {
        if helper.blocked {
            return rekordbox ? "Quit rekordbox to connect: it holds the CDJs' network ports" : "Another copy of Sequent is running: quit it to connect"
        }
        let n = helper.players.count
        if helper.linkList.isEmpty && n == 0 { return "Looking for CDJs: connect one by USB or network" }
        return n == 0 ? "Listening; no CDJs seen yet" : "\(n) CDJ\(n == 1 ? "" : "s") found"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if helper.blocked { rekordbox = rekordboxRunning() }
        if let update {
            let get = NSMenuItem(title: "Sequent \(update) is out: download it…", action: #selector(openDownload), keyEquivalent: "")
            get.target = self
            menu.addItem(get)
            menu.addItem(.separator())
        }
        let header = NSMenuItem(title: status(), action: nil, keyEquivalent: ""); header.isEnabled = false
        menu.addItem(header)
        for d in helper.players { let i = NSMenuItem(title: "   " + helper.line(for: d), action: nil, keyEquivalent: ""); i.isEnabled = false; menu.addItem(i) }
        // Leading the decks, while the page carries on after they stop.
        if let n = helper.leader.number {
            let i = NSMenuItem(title: "   Sequent leading as player \(n)" + (helper.leader.master ? " · tempo master" : helper.leader.leading ? " · asking for master" : " · handing back"), action: nil, keyEquivalent: "")
            i.isEnabled = false; menu.addItem(i)
        }
        let pages = helper.clients.count
        if let h = helper.hopSummary, Date().timeIntervalSince1970 * 1000 - helper.hopsTold < 10_000 {
            let i = NSMenuItem(title: String(format: "   Via iPhone over Wi-Fi: %.0f ms typical, %.0f ms at worst", h.median, h.p95), action: nil, keyEquivalent: "")
            i.isEnabled = false; menu.addItem(i)
        }
        let p = NSMenuItem(title: pages == 0 ? "No Sequent page connected" : "\(pages) Sequent page\(pages == 1 ? "" : "s") connected", action: nil, keyEquivalent: ""); p.isEnabled = false
        menu.addItem(p)
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Sequent", action: #selector(openSite), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)
        let login = NSMenuItem(title: "Start at login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        // The version, at a glance, for anyone asked which they have.
        let version = NSMenuItem(title: "Sequent \(APP_VERSION)", action: nil, keyEquivalent: ""); version.isEnabled = false
        menu.addItem(version)
        let about = NSMenuItem(title: "About Sequent", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(NSMenuItem(title: "Quit Sequent", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc func openSite() { NSWorkspace.shared.open(SITE) }
    @objc func openDownload() { NSWorkspace.shared.open(DOWNLOAD_PAGE) }
    // The standard About panel: the icon, the version from Info.plist, and the
    // credit to Deep Symmetry, whose work Sequent took its inspiration from and
    // who worked out and published the protocol it speaks. A menu-bar app has no window to come forward from, so it
    // brings itself forward first or the panel opens behind everything.
    @objc func showAbout() {
        let lead = "Sequent took inspiration from the amazing work carried out by Deep Symmetry: "
        let credits = NSMutableAttributedString(string: lead)
        credits.append(NSAttributedString(string: "their DJ Link research", attributes: [.link: RESEARCH]))
        credits.append(NSAttributedString(string: ", the Pro DJ Link protocol they worked out and published.\n\nturpin.studio"))
        let all = NSRange(location: 0, length: credits.length)
        credits.addAttribute(.font, value: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), range: all)
        credits.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: 0, length: (lead as NSString).length))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits, .applicationName: "Sequent"])
    }
    @objc func toggleLogin() {
        do { SMAppService.mainApp.status == .enabled ? try SMAppService.mainApp.unregister() : try SMAppService.mainApp.register() }
        catch {
            let a = NSAlert(); a.messageText = "Couldn't change Start at login"
            a.informativeText = "macOS said: \(error.localizedDescription). You can add Sequent in System Settings › General › Login Items instead."
            a.runModal()
        }
    }
}

// MARK: - Entry: --selftest decodes captured packets, as the tests do

// --selftest-lead runs leading through its cases with made-up decks and
// prints what it would send, one line each, for tools/check_lead.py; and
// decodes our own status and beat packets with the decoder that reads the
// real decks, so the offsets are checked against it.
if CommandLine.arguments.contains("--selftest-lead") {
    setvbuf(stdout, nil, _IONBF, 0)
    let hex = { (p: [UInt8]) in p.map { String(format: "%02x", $0) }.joined() }
    func show(_ o: Out) -> String {
        switch o {
        case let .announceAs(n): return "announce \(n)"
        case let .status(p): return "status len=\(p.count) master=\(p[0x89] & 0x20 != 0 ? 1 : 0) playing=\(p[0x89] & 0x40 != 0 ? 1 : 0) synced=\(p[0x89] & 0x10 != 0 ? 1 : 0) Mm=\(p[0x9e]) Mh=\(String(format: "%02x", p[0x9f])) sync=\(u32(p, 0x84)) beat=\(u32(p, 0xa0))"
        case let .beat(p): return "beat len=\(p.count) number=\(p[0x21]) inbar=\(p[0x5c]) bpm=\(u16(p, 0x5a)) next=\(u32(p, 0x24)) bar=\(u32(p, 0x2c))"
        case let .unicast(p, ip, port): return "unicast \(ip):\(port) kind=\(String(format: "%02x", p[0x0a])) " + hex(Array(p[0x1f...]))
        }
    }
    func run(_ name: String, _ steps: (Leader) -> Void) {
        print("# " + name)
        let l = Leader(); l.out = { print(show($0)) }
        steps(l)
    }
    // A deck's status as a real deck would send it: master, handing over to whom, its sync counter.
    func deck(_ n: UInt8, master: Bool, yieldingTo: UInt8 = 0xff, sync: Int = 3) -> [UInt8] {
        statusPacket(number: n, playing: false, master: master, synced: true, handoff: yieldingTo, tempo: 124, beat: 0, beatInBar: 1, sync: sync, counter: 1)
    }
    let two: Players = [1: ("169.254.1.1", false, false, true), 2: ("169.254.2.2", false, false, true)]
    run("nobody is master") { l in
        l.lead(playing: true, tempo: 124, beatInBar: 1, players: two, now: 0)
        l.tick(now: 0.2, players: two)
        l.beatNow(beatInBar: 2)
        l.lead(playing: false, tempo: 0, beatInBar: 1, players: two, now: 1)
        l.tick(now: 1.5, players: two)
        l.tick(now: 2.2, players: two)
    }
    let oneMaster: Players = [1: ("169.254.1.1", true, false, true), 2: ("169.254.2.2", false, false, true)]
    run("deck 1 is master: asked once our status has gone out, it hands over") { l in
        l.lead(playing: true, tempo: 124, beatInBar: 1, players: oneMaster, now: 0)
        l.tick(now: 0.2, players: oneMaster)
        l.tick(now: 0.6, players: oneMaster)
        l.status(deck(1, master: true, yieldingTo: 4))
        l.tick(now: 0.4, players: oneMaster)
        l.status(deck(1, master: false, sync: 5))
        print("master \(l.master)")
    }
    run("deck 1 never answers, so it is asked again") { l in
        l.lead(playing: true, tempo: 124, beatInBar: 1, players: oneMaster, now: 0)
        l.tick(now: 0.6, players: oneMaster)
        l.tick(now: 1.6, players: oneMaster)
        l.lead(playing: true, tempo: 124, beatInBar: 2, players: oneMaster, now: 2.5)
        l.tick(now: 2.8, players: oneMaster)
    }
    run("a stopped master hands over unasked as soon as it sees our status") { l in
        l.lead(playing: true, tempo: 124, beatInBar: 1, players: oneMaster, now: 0)
        l.tick(now: 0.2, players: oneMaster)
        l.status(deck(1, master: true, yieldingTo: 4))
        l.tick(now: 0.4, players: oneMaster)
        l.lead(playing: true, tempo: 124, beatInBar: 2, players: oneMaster, now: 2.5)
        l.tick(now: 3, players: oneMaster)
    }
    run("deck 2 asks for master back, and keeps it") { l in
        l.lead(playing: true, tempo: 124, beatInBar: 1, players: two, now: 0)
        l.status(deck(2, master: false, sync: 7))
        l.requested(by: 2, ip: "169.254.2.2")
        l.tick(now: 0.2, players: two)
        l.status(deck(2, master: true))
        print("master \(l.master)")
        l.tick(now: 0.4, players: two)
        let deck2Master: Players = [1: ("169.254.1.1", false, false, true), 2: ("169.254.2.2", true, true, true)]
        l.lead(playing: true, tempo: 124, beatInBar: 2, players: deck2Master, now: 2.5)
        l.tick(now: 3, players: deck2Master)
    }
    let synced: Players = [1: ("169.254.1.1", false, false, true), 2: ("169.254.2.2", false, true, true)]
    run("the page stops with deck 2 playing in sync") { l in
        l.lead(playing: true, tempo: 124, beatInBar: 1, players: synced, now: 0)
        l.lead(playing: false, tempo: 0, beatInBar: 1, players: synced, now: 1)
        l.tick(now: 1.2, players: synced)
        l.status(deck(2, master: true))
        l.tick(now: 2.1, players: synced)
    }
    run("the page goes quiet, so leading stops") { l in
        l.lead(playing: true, tempo: 124, beatInBar: 1, players: two, now: 0)
        l.tick(now: 1, players: two)
        l.tick(now: 2.5, players: two)
        l.tick(now: 3.7, players: two)
    }
    run("quitting while leading says so first") { l in
        l.lead(playing: true, tempo: 124, beatInBar: 1, players: two, now: 0)
        l.leave()
        print("number \(l.number.map(String.init) ?? "none")")
    }
    let full: Players = [1: ("a", false, false, false), 2: ("b", false, false, false), 3: ("c", false, false, false), 4: ("d", false, false, false)]
    run("four decks: no number to lead as") { l in
        l.lead(playing: true, tempo: 124, beatInBar: 1, players: full, now: 0)
        l.tick(now: 0.2, players: full)
        print("number \(l.number.map(String.init) ?? "none")")
    }
    run("the page plays again while handing over: the handover is called off") { l in
        l.lead(playing: true, tempo: 124, beatInBar: 1, players: synced, now: 0)
        l.lead(playing: false, tempo: 0, beatInBar: 1, players: synced, now: 1)
        l.tick(now: 1.2, players: synced)
        l.lead(playing: true, tempo: 124, beatInBar: 1, players: synced, now: 1.5)
        l.tick(now: 1.7, players: synced)
        l.status(deck(2, master: false))
        l.lead(playing: true, tempo: 124, beatInBar: 1, players: synced, now: 3.4)
        l.tick(now: 3.6, players: synced)
        print("master \(l.master)")
    }
    let deck2Master: Players = [1: ("169.254.1.1", false, false, true), 2: ("169.254.2.2", true, true, true)]
    run("a deck takes master unasked, and isn't asked for it back while the page plays") { l in
        l.lead(playing: true, tempo: 124, beatInBar: 1, players: two, now: 0)
        l.tick(now: 0.2, players: two)
        l.status(deck(2, master: true))
        print("master \(l.master)")
        for now in stride(from: 1.0, through: 7.0, by: 1.5) {
            l.lead(playing: true, tempo: 124, beatInBar: 1, players: deck2Master, now: now)
            l.tick(now: now + 0.2, players: deck2Master)
        }
    }
    run("handed to deck 2, which never takes it: let go after four seconds") { l in
        l.lead(playing: true, tempo: 124, beatInBar: 1, players: synced, now: 0)
        l.lead(playing: false, tempo: 0, beatInBar: 1, players: synced, now: 1)
        l.tick(now: 1.2, players: synced)
        l.tick(now: 3, players: synced)
        l.tick(now: 4.9, players: synced)
        l.tick(now: 5.1, players: synced)
        l.tick(now: 5.3, players: synced)
    }
    run("a request is agreed to only as master, and never from our own number") { l in
        l.lead(playing: true, tempo: 124, beatInBar: 1, players: oneMaster, now: 0)
        l.requested(by: 2, ip: "169.254.2.2")
        l.status(deck(1, master: true, yieldingTo: 4))
        l.requested(by: 4, ip: "169.254.9.9")
        l.tick(now: 0.2, players: oneMaster)
        print("master \(l.master)")
    }
    run("a deck handing over after the page has stopped isn't taken up") { l in
        l.lead(playing: true, tempo: 124, beatInBar: 1, players: oneMaster, now: 0)
        l.lead(playing: false, tempo: 0, beatInBar: 1, players: oneMaster, now: 0.5)
        l.status(deck(1, master: true, yieldingTo: 4))
        print("master \(l.master)")
        l.tick(now: 1.6, players: oneMaster)
    }
    run("our own status, a short packet and a deck not master change nothing") { l in
        l.lead(playing: true, tempo: 124, beatInBar: 1, players: two, now: 0)
        l.status(deck(4, master: true))
        l.status(Array(deck(2, master: true).prefix(0x90)))
        l.status(deck(2, master: false, yieldingTo: 4, sync: 9))
        l.tick(now: 0.2, players: two)
        print("master \(l.master)")
    }
    run("beats only while leading, and a page's nonsense tempo is passed over") { l in
        l.beatNow(beatInBar: 1)
        l.tick(now: 0, players: two)
        l.lead(playing: true, tempo: 124, beatInBar: 1, players: two, now: 0)
        l.lead(playing: true, tempo: 0, beatInBar: 0, players: two, now: 0.1)
        l.lead(playing: true, tempo: -3, beatInBar: 7, players: two, now: 0.2)
        l.beatNow(beatInBar: 2)
        l.lead(playing: true, tempo: 128.5, beatInBar: 3, players: two, now: 0.3)
        l.beatNow(beatInBar: 3)
        l.lead(playing: false, tempo: 0, beatInBar: 1, players: two, now: 0.4)
        l.beatNow(beatInBar: 4)
    }
    run("playing again after letting go: announced afresh, and master again") { l in
        l.lead(playing: true, tempo: 124, beatInBar: 1, players: two, now: 0)
        l.lead(playing: false, tempo: 0, beatInBar: 1, players: two, now: 1)
        l.tick(now: 2.2, players: two)
        l.tick(now: 2.4, players: two)
        l.lead(playing: true, tempo: 124, beatInBar: 1, players: two, now: 3)
        l.tick(now: 3.2, players: two)
    }
    run("with deck 4 on the link, Sequent leads as player 3") { l in
        let deck4: Players = [4: ("169.254.4.4", false, true, true)]
        l.lead(playing: true, tempo: 124, beatInBar: 1, players: deck4, now: 0)
        l.status(deck(3, master: true))
        l.tick(now: 0.2, players: deck4)
        print("number \(l.number.map(String.init) ?? "none")")
    }
    print("# decoded")
    print(String(decoding: json(parse(port: STATUS_PORT, statusPacket(number: 4, playing: true, master: true, synced: true, handoff: 0xff, tempo: 124.5, beat: 9, beatInBar: 3, sync: 2, counter: 1))!), as: UTF8.self))
    print(String(decoding: json(parse(port: BEAT_PORT, beatPacket(number: 4, tempo: 124.5, beatInBar: 3))!), as: UTF8.self))
    exit(0)
}

// --selftest-forward checks reading a phone's packets and the delay figures,
// for tools/check_forward.py.
if CommandLine.arguments.contains("--selftest-forward") {
    let d: [UInt8] = Array("SQFW".utf8) + [1, 0xc3, 0x51, 169, 254, 11, 117] + [0, 0, 1, 0x9a, 0x1b, 0x7c, 0x2a, 0x3b] + Array("Qspt1WmJOL".utf8) + [0x28]
    if let f = forwarded(d) { print("forwarded port=\(f.port) from=\(f.source.map(String.init).joined(separator: ".")) heard=\(Int(f.heardMs)) bytes=\(f.packet.count)") }
    print("refused \(forwarded(Array("hello world, not ours".utf8)) == nil) \(forwarded(Array(d.prefix(19))) == nil)")
    let t1: UInt64 = 1_791_500_000_000_000_000, ms: UInt64 = 1_000_000
    let even = clockSync(t1: t1, t2: t1 + 38 * ms, t3: t1 + 39 * ms, t4: t1 + 17 * ms)
    let uneven = clockSync(t1: t1, t2: t1 + 32 * ms, t3: t1 + 33 * ms, t4: t1 + 17 * ms)
    print("sync offset=\(even.offset) roundTrip=\(even.roundTrip); uneven offset=\(uneven.offset) roundTrip=\(uneven.roundTrip)")
    if let back = pongTimes(Array("SQPO".utf8) + [1] + pingPacket(7).suffix(8) + pingPacket(8).suffix(8) + pingPacket(9).suffix(8)) { print("pong \(back.t1) \(back.t2) \(back.t3)") }
    for delays in [[40.0, 52, 41, 47, 90, 40.5, 43, 44, 45, 46, 60, 42, 41, 48, 49, 50, 51, 43, 44, 45], [5.0], [Double]()] {
        if let h = hopStats(delays) { print(String(format: "hops base=%.1f median=%.1f p95=%.1f", h.base, h.median, h.p95)) } else { print("hops none") }
    }
    exit(0)
}

if CommandLine.arguments.contains("--selftest") {
    // Decode each file given as port:path and print it as the page would get it.
    for arg in CommandLine.arguments.drop(while: { $0 != "--selftest" }).dropFirst() {
        let parts = arg.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let port = UInt16(parts[0]), let d = FileManager.default.contents(atPath: String(parts[1])) else { continue }
        if let m = parse(port: port, Array(d)) { print(String(decoding: json(m), as: UTF8.self)) } else { print("null") }
    }
    print(dbMessage(tx: 1, kind: 0x2002, args: [5, 6]).map { String(format: "%02x", $0) }.joined())
    print(announcement(number: 7, ip: [169, 254, 38, 85], mac: [0xc8, 0x3d, 0xfc, 0x1c, 0xe5, 0xd1]).map { String(format: "%02x", $0) }.joined())
    // Which pages may connect, as 1 or 0 for each, the same list as Linux's.
    print("origins " + ["https://turpin.studio", "http://localhost:8793", "http://127.0.0.1", "https://midi.turpin.studio", "https://a.b.turpin.studio", "http://midi.turpin.studio", "https://midi.turpin.studio:8443", "https://turpin.studio.evil.com", "https://evilturpin.studio", "https://-x.turpin.studio", "http://localhost.evil.com", "null", ""].map { allowed($0) ? "1" : "0" }.joined())
    exit(0)
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
