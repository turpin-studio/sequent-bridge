# The bridge's WebSocket, version 1

What Sequent.app and Sequent for Linux send to the apps that connect to them,
written down on 12 October 2026 as it already was, so that apps other than
the instruments page can rely on it. This is **version 1**: the messages as
they are, shaped around Pro DJ Link.

`helper/mac/main.swift` and `helper/linux/sequent` are the reference;
`tools/fixtures/selftest.expected` pins the decoding both must agree on.

## Connecting

- `ws://127.0.0.1:8795/`, on this computer only: the bridge listens on the
  loopback address and nowhere else.
- The bridge admits only these `Origin`s:
  - `https://turpin.studio`, `http://localhost` and `http://127.0.0.1`, each
    with any port;
  - any `https://<name>.turpin.studio`, so each of the studio's apps can live
    on its own subdomain, such as `midi.turpin.studio`. Https only, no port,
    and only DNS labels, so a lookalike such as `turpin.studio.example.com`
    is refused. The Mac app has this from the release after 0.3.1.

  Anything else is refused before the upgrade (Linux answers 403, the Mac
  app 400), so a page on another site can't read what is playing.
- **The app sends nothing.** The bridge reads only to notice a close.
- Every message is one text frame of JSON, keys sorted, one object.
- A browser asks before a public page reaches a local address (Chrome's
  local network access), so an app should connect only after the person has
  chosen to, as the instruments page does with its Connect button.

## Fields every message carries

Every message except `hello` has:

| Field | Type | Meaning |
| --- | --- | --- |
| `type` | string | which message, below |
| `number` | integer | the device's player number, 1 to 6 for decks |
| `t` | integer | when the bridge received it, milliseconds since 1970 |
| `from` | string | the sender's IPv4 address |

`t` is the bridge's own arrival time. It is stamped before the message
reaches the app, so an app can time beats by it rather than by its own,
later, delivery.

## `hello`

Sent once, first, on connecting.

| Field | Type | Meaning |
| --- | --- | --- |
| `version` | string | the bridge's version, `X.Y.Z`; `0.0.0` or a `-dev.N` suffix for a build that isn't a release |
| `platform` | string, optional | `"linux"` from Sequent for Linux; absent from the Mac app |
| `devices` | array | the last `device` message from each device seen |
| `statuses` | array | the last `status` message from each player |

## `device`

A device announcing itself on the network, every couple of seconds. Passed
on when it changes, and otherwise at most once every four seconds.

| Field | Type | Meaning |
| --- | --- | --- |
| `name` | string | the model, such as `CDJ-3000X` |
| `ip` | string | its address |

## `beat`

On every beat of a playing deck.

| Field | Type | Meaning |
| --- | --- | --- |
| `name` | string | the model |
| `bpm` | number | the track's own tempo |
| `pitch` | number | the tempo fader, percent, two decimals |
| `tempo` | number | what is playing: `bpm × (1 + pitch / 100)`, two decimals |
| `beat` | integer | the beat within the bar, 1 to 4 |
| `nextBeatMs` | integer | milliseconds to the next beat, at this tempo |
| `nextBarMs` | integer | milliseconds to the next bar's first beat |

## `status`

A player's state. Players send several a second; the bridge passes on any
change at once and otherwise one a second. Players send status only to
devices that have announced, so a bridge started with `--listen-only` sends
none.

| Field | Type | Meaning |
| --- | --- | --- |
| `name` | string | the model |
| `firmware` | string | its firmware version, such as `1.40` |
| `playing` | boolean | the deck is playing |
| `master` | boolean | it is the tempo master |
| `sync` | boolean | sync is on |
| `onAir` | boolean | the mixer says its channel is live |
| `bpm` | number or null | the track's tempo; `null` with no track loaded |
| `pitch` | number | the tempo fader, percent, two decimals |
| `key` | string, optional | the key heard, such as `Bbm` or `F#`, Key Shift included; CDJ-3000 and 3000X only, and absent with no track |
| `source` | integer | the player whose media holds the track |
| `slot` | integer | which slot on it: 2 SD, 3 USB, 4 rekordbox |
| `trackType` | integer | 1 for a rekordbox track |
| `rekordboxId` | integer | the track's ID in that media's database, 0 if none |
| `trackNumber` | integer | the track's number in the player's list |
| `title`, `artist`, `album` | string, optional | from the source deck's database, for a rekordbox track only, once looked up |

When a lookup finishes, the bridge sends every stored status for that track
again with the details added, so an app has them without waiting for a
change. The deck's own `key` wins over the database's.

## `master`

The players handing over the tempo master between themselves.

| Field | Type | Meaning |
| --- | --- | --- |
| `kind` | string | `"request"` or `"response"` |

## `other`

Any other Pro DJ Link packet on the ports the bridge reads, so a log can
show it rather than lose it. A playing CDJ-3000 sends many of these a
second, so an app that logs them should expect the volume.

| Field | Type | Meaning |
| --- | --- | --- |
| `port` | integer | the UDP port it came in on |
| `kind` | integer | the packet's kind byte |

## Changing it

- Within version 1, only add: a new optional field, or a new `type`. Apps
  must ignore what they don't know.
- Anything that renames, removes or changes the meaning of a field is
  version 2.
- A change to the decoding updates `tools/fixtures/selftest.expected`, which
  both bridges must reproduce, from a build tried with real decks.
