# Pro DJ Link in Sequent

Which parts of the Pro DJ Link protocol Sequent uses, what it sends, and what
our own decks (two CDJ-3000Xs on firmware 1.40, and a DJM-750MK2) have
shown. It is not a protocol reference: that is
[Deep Symmetry's DJ Link analysis][djl], whose work all of this rests on, and
packet layouts are left to it rather than copied here.

The code is `helper/mac/main.swift`, and [sequent-app.md](sequent-app.md)
explains how the app is built around it.

## Wireshark

`tools/wireshark/prodjlink.lua` is a dissector for all of it: every packet
type named, with a link to Deep Symmetry's page for it; keep-alives, beats
and CDJ status decoded (status shows the key, Key Shift and the key heard,
and on a 3000X the values that change with the track); and the database
server's messages. Copy it into Wireshark's personal plugins folder (Help,
About Wireshark, Folders), or try it with
`tshark -X lua_script:tools/wireshark/prodjlink.lua -r capture.pcap`.

To capture, with Sequent.app running (the decks only send status to a
device that has announced), on the interface the decks are on:
`tcpdump -i en8 -w capture.pcap 'udp portrange 50000-50002 or tcp'`. On
this Mac that needs no administrator rights. Checked against a capture of
two 3000Xs on 8 October 2026; the database part hasn't seen real traffic.

[djl]: https://djl-analysis.deepsymmetry.org/

## What Sequent.app reads

| Packet | Port | Sequent uses it for | Deep Symmetry |
| --- | --- | --- | --- |
| Device announcement (0x06) | 50000 | The decks on the network, and their addresses | [Startup][startup] |
| Beat (0x28) | 50001 | The tempo and the bar: each beat becomes 24 clock ticks | [Beats][beats] |
| Master handoff (0x26, 0x27) | 50001 | Recognised and passed on; never taken part in | [Sync][sync] |
| Player status (0x0a) | 50002 | Playing, master, sync, on air, tempo, pitch, firmware, the key | [Device status][vcdj] |
| Absolute position (0x0b) | 50001 | Nothing yet; it would give the playhead | [Beats][beats] |

A Mac on USB to a player sees one network per USB link, and each packet
arrives on both, so the app drops a copy seen in the last 50 ms. rekordbox
holds the same ports, so the two can't run on one machine.

[startup]: https://djl-analysis.deepsymmetry.org/djl-analysis/startup.html
[beats]: https://djl-analysis.deepsymmetry.org/djl-analysis/beats.html
[sync]: https://djl-analysis.deepsymmetry.org/djl-analysis/sync.html
[vcdj]: https://djl-analysis.deepsymmetry.org/djl-analysis/vcdj.html

## What Sequent.app sends

Two things that change nothing a deck does, and, only while the page leads
(Mac only, not yet tried with real decks), what a playing synced CDJ sends:
status, beats and the master handoff. See
[sequent-app.md](sequent-app.md#leading).

### Its announcement, as player 7

Players send their status only to devices that have announced, so the app
announces itself on each link-local network every 1.5 seconds, to
169.254.255.255 port 50000, as player 7 so it never takes a real deck's
number. `--listen-only` stops it, and then no status arrives. The bytes, as
`announcement()` builds them:

| Offset | Value |
| --- | --- |
| 0x00 | `Qspt1WmJOL` |
| 0x0a | `06 00` |
| 0x0c–0x1f | "sequent", padded with zeros |
| 0x20–0x23 | `01 02 00 36` |
| 0x24 | `07`, the player number |
| 0x25 | `01` |
| 0x26–0x2b | This link's MAC address |
| 0x2c–0x2f | This link's IP address |
| 0x30–0x35 | `01 00 00 00 01 00` |

### Track details, from a deck's database

For a status naming a rekordbox track, the app asks the source deck's
database server (TCP 12523) for the title, artist, album and key, as
`metadata()` does, following Deep Symmetry's
[track metadata][meta] notes: posing as a real player number (1 to 4, one
that isn't the source deck), since the decks don't answer player 7. **It has
never run against a real track**: our 3000Xs don't fill in the track's
identity (below). It is tested against a fake server only.

[meta]: https://djl-analysis.deepsymmetry.org/djl-analysis/track_metadata.html

## What our CDJ-3000Xs showed

- **The status packet is 1152 bytes** (`lenr` 0x045c), with the documented
  CDJ-3000 fields where Deep Symmetry place them: tempo, pitch, flags,
  firmware.
- **The key and Key Shift are where Deep Symmetry document them for the
  CDJ-3000**, at 0x15c and 0x164, and read correctly on the 3000X:
  confirmed on 8 October 2026 with a B♭ minor track (`01 00 ff`), an F minor
  one (`08 00 00`), and a Key Shift of +100 and then −200. `statusKey()`
  decodes it, and the page's key section follows it. (We first took this for
  a finding of our own and read it wrong; their table was right.)
- **The track's identity is missing.** Source player, slot, track type and
  rekordbox ID are all zero with tracks loaded, on both decks, on 5 and 8
  October, so the database lookup has nothing to ask for. Numbers that
  change with the track sit just after those fields (0x34–0x47) and repeat
  as a block about six times further on (from 0x18c), each copy beside what
  looks like a cue entry; the block adds one more at 0x194 (219 and 60 on
  our two decks). Which of them is an ID is unknown. `Sequent
  --capture DIR` saves a deck's status packet whenever those bytes change,
  for loading known tracks against.
- **A packet type Deep Symmetry don't list: 0x80 on port 50002.** Each
  3000X sends it four times a second, only to the announced device (Sequent
  as player 7), 44 bytes: the usual name and device number, eight bytes
  remaining, and that device's player number at 0x26. Perhaps an
  acknowledgement of the announcement; unknown.
- **The beat grid can be loose**: one track at 92.54 BPM ran 600 to 668 ms
  between beats, the same shape every bar.

## What an XDJ-RX showed

On a direct Ethernet cable, 11 October 2026: it announces as device 11,
device class 2 (the class mixers use), its keep-alive ending `01 00 00 00
07 00`; it claims its number every 0.3 s on start-up, then keeps alive every
2 s. With a track playing it sent no beat packets and, with nobody
announcing, no status. When Sequent.app announced as player 7 it froze and
needed a reboot, possibly in reaction (#3). Its USB is MIDI only,
and silent.

## What others have mapped that Sequent doesn't use yet

From David Ng's [wireshark-prodj-dissectors][nudge] (Apache 2.0, built on
Deep Symmetry's dysentery), checked against our own recording on 11 October
2026. Facts only; nothing of theirs is copied.

- **Absolute position** (beat port 50001, type `0x0b`, 60 bytes): track
  length, playhead in milliseconds, pitch and tempo. A CDJ-3000X sends one
  about every 30 ms: 3,971 of them in our two-minute recording, against 211
  beat packets. Sequent reads only the beats. Position would let it follow
  cue jumps, loops and platter nudges at once, and let the stems page lock
  to the deck's playhead when the same tune is loaded on it.
- **Master Tempo** (status `0x158`, off or on). With it off, the pitch fader
  moves the key too, which the key Sequent follows doesn't allow for: at +6%
  the deck is a semitone above it.
- **The deck's loop** (status `0x1b6` start, `0x1be` end, `0x1c8` beats).
- **Link Cue audio** (port 50004, types `0x1e` data, `0x1f` handover, `0x20`
  timing): the CDJ-3000s stream audio to one another for headphone preview.
- Play states, a cue countdown (`0xa4`), buffer status (`0x11d` to `0x11f`),
  waveform colour and position, channel on-air (beat port type `0x03`) and a
  mixer's status (status type `0x29`), the last two needing a mixer on the
  link, which the DJM-750MK2 isn't.

[nudge]: https://github.com/nudge/wireshark-prodj-dissectors

## Commands Sequent doesn't send

Some packets change what a deck does: fader start, channels on air, sync
control and taking tempo master, loading a track, and loading settings. They
are in Deep Symmetry's [mixer integration][mix], [sync][sync] and
[loading tracks][load] notes. **Only taking tempo master is in Sequent.app**,
when the page leads (above), and none should be sent during a set unless the
DJ asked for it.

Pressing Play on a deck from Sequent would be fader start, which Deep
Symmetry note the CDJ-3000 doesn't support, so a 3000X probably won't
either. Untried.

[mix]: https://djl-analysis.deepsymmetry.org/djl-analysis/mixer_integration.html
[load]: https://djl-analysis.deepsymmetry.org/djl-analysis/loading_tracks.html
