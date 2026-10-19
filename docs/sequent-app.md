# Inside Sequent.app

What the Mac menu-bar app is made of, and why each part works the way it
does. The [README](../README.md) says what the app is for and how it's built,
signed and released; this is for changing its code. It is one file,
`helper/mac/main.swift`, about 580 lines, built with the command-line tools
and no Xcode project.

## Why it exists

A browser can't open a UDP socket, and Pro DJ Link is UDP broadcast. So
something native has to listen for the CDJs and hand what it hears to the
page. That was `tools/djlink.py` until 6 October 2026, which meant asking
people to install Python; the app replaced it and sends the page byte-for-byte
the same messages, so the page didn't change. What they agreed on is pinned in
`tools/fixtures/selftest.expected`, which `--selftest` must still reproduce.

**It sends the players nothing that changes what they do, unless the page
asks it to lead.** It announces itself and asks a deck's database questions;
and only while the page carries on after the decks stop, it leads them
(below). That's the line.

## Leading

With the page's Master toggle on, the page keeps its own time and sends the
app a `lead` message on every beat (docs/websocket.md). The app then leads
the decks, so one with Sync on follows Sequent:

- **It becomes a real player.** Players take a tempo master only from player
  numbers 1 to 4 (beat-link insists on it too), so it announces as the
  highest of those no deck is using, in place of 7, and goes back to 7 when
  it's done. With four decks there's no number free, and it doesn't lead.
- **It sends status and beats like a playing, synced CDJ**: status to every
  player five times a second, and a beat packet, broadcast, as each of the
  page's beats is heard (its own timer, a millisecond's leeway; measured
  about 1.5 ms after the moment the page gave). The templates are the ones
  beat-link sends, as facts of the protocol; offsets are Deep Symmetry's.
- **It takes the master role** at once if nobody has it, else by asking the
  master (a handoff request, 0x26, every two seconds until answered) and
  taking it when that player's status names it in the handoff byte (0x9f).
  A stopped master also hands over unasked to a synced, playing player.
- **It gives the role back**: a player asking for it is answered (0x27, to
  both ports, since Deep Symmetry's notes say 50001 and beat-link uses
  50002) and named in our handoff byte, and when it asserts master we let
  go, our sync counter one above the players'. When the page stops leading
  it hands master to a player playing in sync, or just lets it go, and a
  second later (four at most) announces as 7 again. Still master then, as
  that player never took it, it first sends a last status saying it isn't,
  as on quitting. The page playing again meanwhile calls the handover off.
- **A deck that takes master keeps it.** The request is repeated only until
  Sequent has held master once; after a deck takes it (its MASTER button),
  that's the DJ's choice and isn't fought over, and the page switches its
  toggle off on seeing `leading` with master false.
- **Its own packets are dropped** on the way in, by source address, so it
  never takes its own announcements and beats for a deck.

The decisions are `Leader`, apart from the sockets and timers, and
`--selftest-lead` runs it through its cases with made-up decks;
`tools/check_lead.py` compares that with `tools/fixtures/lead.expected`, and
decodes our own status and beat packets with the decoder that reads the real
decks. The menu shows "Sequent leading as player 4 · tempo master" while it
does. The Linux bridge doesn't lead: it ignores `lead`.

**On the rig, 17 October 2026** (one CDJ-3000X, firmware 1.40, recorded in
`tools/recordings/lead-test-2026-10-17-en8.pcap`): with the deck cued, the
master, Sequent led as player 4 and the deck handed it master within 20 ms
of seeing its status, unasked. Played with Sync on, the deck followed:
every beat on Sequent's beat in the bar, within 8 ms, its tempo settling
from its own track's 120 to Sequent's 122.95 BPM. When the page followed the
deck again, Sequent named it in the handoff byte and it took master 37 ms
later. Two things learned: our status started three seconds late, its
run-loop timer scheduled from a WebSocket callback going unnoticed until the
run loop next woke, so it's a dispatch timer now; and the deck ignored a
handoff request sent before it had had any status from player 4, so the
request now waits for our status to be going. A copy quit while it held master
left the deck sending its status to nobody until it was replugged, so
quitting while leading now sends a last status, stopped and not master,
before announcing as 7 again; and a page gone quiet for two seconds (closed,
asleep) stops the leading as if it had said so.

## The shape of it

Four layers, in the order they appear in the file:

1. **Decoding** — pure functions over `[UInt8]`, no state and no I/O.
   `parse(port:_:)` turns a packet into a `Message` (`[String: Any]`),
   `announcement(number:ip:mac:)` builds the packet that says we're here.
   These are what `--selftest` exercises, and the only part testable without
   hardware.
2. **The links** — `links()` walks `getifaddrs` for every interface holding a
   link-local (169.254.x.x) address, and pairs it with that interface's MAC.
3. **The deck's database** — a small blocking TCP client, `Socket` and
   `metadata()`, run off the main thread.
4. **The helper and the app** — `Helper` owns the sockets, the state and the
   WebSocket; `App` is the menu bar.

## Decoding

The layouts come from [Deep Symmetry's DJ Link
analysis](https://djl-analysis.deepsymmetry.org/). Every packet starts with
the ten-byte magic `Qspt1WmJOL` and carries its kind at `0x0a`. Three matter:

| Port | Kind | Meaning |
| --- | --- | --- |
| 50000 | `0x06` | a device announcing itself |
| 50001 | `0x28` | a beat |
| 50002 | `0x0a` | a player's status |

Anything else decodes to `{"type": "other"}` with its port and kind, so the
page's packet log shows it rather than swallowing it.

Two decoding details worth knowing:

- **Pitch is a 21-bit fixed-point number** around `0x100000`, which is 0%.
  `(u32(p, 0x54) - 0x100000) / 0x100000 * 100` gives the percentage, and the
  tempo in play is `bpm * (1 + pitch / 100)`. Status packets carry pitch and
  BPM but no combined tempo, so the menu recomputes it.
- **`bpm == 0xffff` means no track**, and becomes `null` rather than 655.35.

`parse` guards `p.count >= 0x22` up front, and each branch guards the length
its own fields need. The two branches that read only `p[0x21]` rely on that
first guard being exactly one byte larger — fine today, worth remembering if
anyone relaxes it.

## Announcing, and why

The players send status (track loaded, playing, master) **only to devices
that have announced themselves**. Listening alone gets beats and device
announcements and nothing else. So the app announces as player 7 — outside
the 1–4 a real CDJ uses, and outside the 1–6 the menu lists — every 1.5 s,
on each link, to `169.254.255.255`.

`--listen-only` announces nothing and doesn't even bind 50002. It's the
honest mode: it can't make a player do anything, at the cost of no status.

**Why one sender socket per link.** A Mac with two CDJs on USB has two
link-local interfaces, and a broadcast has to go out of each one explicitly —
bound to that interface's own address. `refreshLinks()` rebuilds the senders
whenever the set of interfaces or their addresses changes, every 10 s.

**Why the same packet arrives twice.** Each USB link is its own network, and
the decks broadcast on both, so every packet is seen once per link. The
duplicate is dropped by remembering the exact bytes for 50 ms (`seen`).

## Ports, and rekordbox

rekordbox holds 50000–50002 itself, so both can't run at once. `bindPorts()`
therefore **retries on a 1.5 s timer** rather than failing at launch, and sets
`blocked` when it can't get them. The menu turns that into advice: if
rekordbox is running, say so; otherwise it's another copy of Sequent.

`SEQUENT_PORT_OFFSET` moves all three ports so a test copy can run beside a
real one. With it set, no CDJ will hear or be heard — it's for development
only.

## Status: several a second, in and out

A player sends status several times a second whether anything changed or not.
`statusChanged()` decides what reaches the page: a change goes straight
through, and an unchanged status goes through at most once a second as a
keep-alive. The comparison strips `t` and `from` first, since those differ
every time.

## Track metadata

A status packet names a track by `source` (which player's media), `slot` and
a rekordbox ID — not by title. The title, artist, album and key come from
asking that source deck's database server on TCP 12523.

Three things make this awkward, and the code carries all three:

- **You have to pose as a real player**, 1 to 4, as beat-link does. The app's
  own player 7 isn't answered. It picks a number that isn't the source deck's.
- **It's blocking**, so it runs on a global queue and posts back to main.
  Each `(source, slot, id)` is looked up once and cached in `tracks`; the
  entry is reserved before the lookup starts so a burst of status packets
  can't fire several.
- **It has to go out of the right interface**, so it tries each link's local
  address in turn.

When the answer arrives, every stored status matching that key is amended and
rebroadcast, so a page that already has the track gets its title without
waiting for the next change.

**This path has never run against a real rekordbox track.** On 5 October 2026
both CDJ-3000Xs reported source, slot and ID all zero with tracks loaded, so
there was nothing to fetch. It's tested against a fake database server only.

The 3000X's status packet is 1152 bytes, far longer than the CDJ-3000's
documented layout, and the bytes that look like track identity sit about
12 bytes later than the documented ones (deck 1 on 5 October had
`33 86 2d 07` at 0x38, repeated at 0x19c), so the X may name its track in a
new layout. To work it out, run the app from Terminal with
`--capture DIR`: it saves a deck's raw status packet to DIR each time the
bytes around the track's identity (0x24–0x47 and 0x180–0x1af) change, and
prints each save with those bytes in hex. Quit any other copy first, since
it needs the same ports. Then load known tracks one at a time and note which
went where.

[pro-dj-link.md](pro-dj-link.md) says which packets the app reads and sends,
and what our 3000Xs showed.

**The key.** Every status packet carries the deck's key and Key Shift, at
0x15c and 0x164, as Deep Symmetry document for the CDJ-3000 (dysentery's
device status notes); the 3000X matches. `statusKey()` gives the key heard,
as text such as `Bbm`: the key moved by the shift. Minor keys count up from
A and major keys from C. It needs no database lookup, so it works whether or
not the track's identity is known. Confirmed with the decks on 8 October
2026; `status-deck1-keyshift.bin` is a capture with a Key Shift of −200.

## Passed on by a phone

Sequent on an iPhone, on the decks' link by a USB-C cable to a CDJ, can pass
every Pro DJ Link packet it hears to Sequent.app over Wi-Fi, so the page on
a Mac follows decks the Mac isn't wired to. The app advertises
`_sequent._udp` by Bonjour; the phone finds it and sends each packet as one
datagram: `SQFW`, version 1, the port it arrived on, the deck's address,
when the phone heard it, then the packet as it was (the format is in
turpin-studio/sequent-apple, `SequentCore/Forward.swift`). `forwarded()`
reads it and `handle()` takes it from there exactly as a deck's own packet,
the deck's address and all.

Unicast to an address Bonjour found needs Local Network access only, not
Apple's multicast entitlement. What doesn't come through: leading, which
needs the decks to hear this Mac, and track details, which the Mac would
ask the deck for over a link it isn't on. Wi-Fi delays packets unevenly, so
beats arrive less evenly than over a cable; the page's jitter graph shows
by how much. Only the Mac app listens; the Linux bridge doesn't yet.

Tested on 19 October 2026 with the iPhone app in the simulator, a recording
replayed into it on moved ports and forwarding on: the app's WebSocket
carried the deck's announcement, beats and status, and with the iPhone app
closed, nothing. Then on the rig the same evening: an iPhone (build 25) on a
CDJ-3000X by USB-C, passing it over Wi-Fi to this Mac, whose page followed
the deck. How evenly the beats arrive over Wi-Fi is still to measure.

## The WebSocket

One `NWListener` on 127.0.0.1:8795, with two independent locks:

- `params.requiredInterfaceType = .loopback` and a required local endpoint of
  127.0.0.1, so nothing off this machine can reach it;
- an origin check in the client request handler, `allowed()`, admitting only
  `https://turpin.studio`, any `https://<name>.turpin.studio` (each app on
  its own subdomain) and localhost. The self-test prints its answer for a
  fixed list of origins, lookalikes included, which the Linux bridge must
  match.

A page is sent a `hello` on connect — the app's version, every device seen and
every status — then each message as it arrives. **The page never sends
anything**; `drain()` reads only to notice it leave.

The version in the hello is what lets an app say a newer bridge is out, as
the instruments page at turpin.studio does.

## The menu bar

The icon says the state at a glance: a warning triangle when blocked, radio
waves when CDJs are found, a waveform otherwise. The tempo sits beside it —
the master deck's while it beats, else any deck's, and none after two seconds'
quiet, so it clears when the music stops rather than freezing on a last value.

A 1 s timer refreshes it so that clearing happens even with no packets
arriving, but **only while there's a tempo shown or a deck to age out**; idle,
nothing can change without a packet or a new link, and those refresh it
themselves. `refreshIcon()` runs on every beat, so it touches the menu bar
only when the symbol, title or tooltip actually changes: setting a status
item's image redraws it even when it's the same one. Until 12 October 2026 it
set a fresh image every second regardless, which put an idle app with no
decks in the CPU figures (about 0.2%, against nothing now), and looked for
rekordbox among the running apps every second while blocked; that's now asked
once when the ports are found taken and again when the menu opens. The other
timers carry a tolerance so macOS can fold their wake-ups in with others.

## Threading

**Everything is on the main queue** — both UDP read sources, the WebSocket
listener and its connections, and all the timers — except `metadata()`, which
blocks and runs on a global queue, posting its result back to main. So the
state (`devices`, `statuses`, `tracks`, `beats`, `clients`) needs no locking,
and anything added should keep to that rule or bring its own.

## Testing it

There's no hardware in CI, so `--selftest` is the whole of it: it decodes
captured packets from `tools/fixtures/*.bin`, prints each as the page would
get it, and prints a database message and an announcement as hex.
`tools/check_app.py` runs the built app and compares all of it with
`tools/fixtures/selftest.expected`.

That covers layer 1 completely and layers 2 to 4 not at all. Changing the
socket handling, the announce timer or the WebSocket means testing with real
decks. Captures of new packet kinds are cheap to add and worth adding.

## Known gaps

Open issues against this file:

- #1, the database reader will allocate whatever a length field asks for,
  and its reads have no overall deadline;
- #2, a force-cast in the status path, WebSocket connections retained when
  they never become ready, and per-packet allocations;
- #3, the announcement may freeze an XDJ-RX.
