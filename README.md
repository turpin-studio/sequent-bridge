# Sequent

The bridge between DJ gear and the apps that play along with it.

A browser can't open a UDP socket, and Pioneer's Pro DJ Link is UDP
broadcast. Sequent is the small native app that can: it listens to the CDJs,
follows their tempo, beats, key and status, and hands it all to apps on the
same computer over a local WebSocket. The first of those apps is the set of
instruments at [turpin.studio](https://turpin.studio), which play in time and
in key with the decks.

- **Sequent.app** for macOS 13 and later, a menu-bar app showing the master
  deck's tempo: [helper/mac/main.swift](helper/mac/main.swift), one Swift
  file built with the command-line tools.
- **Sequent for Linux**, in the tray or as a systemd service:
  [helper/linux/sequent](helper/linux/sequent), one Python file packaged as a
  `.deb`.

Both send the same messages, written down in
[docs/websocket.md](docs/websocket.md), and both must reproduce
[tools/fixtures/selftest.expected](tools/fixtures/selftest.expected) from
real CDJ captures.

## Inspired by Deep Symmetry

Sequent took inspiration from the amazing work carried out by Deep Symmetry:
[their DJ Link analysis](https://djl-analysis.deepsymmetry.org/), the Pro
DJ Link protocol they worked out and published, and
[beat-link](https://github.com/Deep-Symmetry/beat-link), which implements it.
Everything Sequent knows about the protocol comes from that analysis. The
code here is written from their documentation, not their code.
[docs/pro-dj-link.md](docs/pro-dj-link.md) lists which parts Sequent uses and
what our own decks (two CDJ-3000Xs and a DJM-750MK2) showed, including the
3000X's 1152-byte status packet and its key and Key Shift.

## What it does

- Listens on UDP 50000 to 50002 for device announcements, beats and status.
- Announces itself as player 7 on each link-local interface, since the
  players send status only to devices that have announced. `--listen-only`
  announces nothing.
- Asks a deck's database server (TCP 12523) for a rekordbox track's title
  and artist, posing as player 1 to 4 as beat-link does.
- Serves a WebSocket on `127.0.0.1:8795` to pages from turpin.studio, its
  https subdomains and localhost only.

It sends the players nothing that changes what they do, with one exception
the page asks for: **leading** (Mac only, not yet released). When the page
carries on after the decks stop, the app can become a player and take the
tempo master role, so a deck with Sync on follows Sequent; see
[docs/sequent-app.md](docs/sequent-app.md#leading).

## Installing

- **macOS:** the signed and notarised disk image from the
  [latest release](https://github.com/turpin-studio/sequent-bridge/releases/latest),
  always at
  [releases/latest/download/Sequent.dmg](https://github.com/turpin-studio/sequent-bridge/releases/latest/download/Sequent.dmg).
  Each release's notes come from [helper/releases.json](helper/releases.json),
  and the app checks the latest release's `latest.json` for updates.
- **Linux:** not released yet; [docs/sequent-linux.md](docs/sequent-linux.md)
  says how to build and install the package, and the one NetworkManager
  setting a CDJ's USB link needs.

rekordbox holds the same ports, so quit it first.

## Building and testing

```sh
make test                       # the Linux self-test and the replayer's tests
make app                        # build/Sequent.app, universal, signed ad hoc
python3 tools/check_app.py build/Sequent.app
make dmg                        # the disk image (needs dmgbuild)
make deb                        # build/Sequent-<version>.deb, on a Mac or Linux
```

With no decks to hand, `make replay` plays a recording of two CDJ-3000Xs
into a running bridge (`SEQUENT_PORT_OFFSET` moves its ports so a test copy
can run beside a real one), and `make record` captures your own.
`tools/wireshark/prodjlink.lua` is a Wireshark dissector for the traffic.

[docs/sequent-app.md](docs/sequent-app.md) explains how the Mac app is put
together and why.

## Licence

[Eclipse Public License 2.0](LICENSE), as beat-link uses. Apps that only talk
to Sequent over its WebSocket are separate works and may use any licence.

Copyright 2026 Dean Turpin.
