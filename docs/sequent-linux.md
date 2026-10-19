# Sequent for Linux

The CDJ connection for Linux: Sequent.app's job, in the tray, as a Debian
package. Added 12 October 2026 and not yet linked from turpin.studio or tried
with real decks. [sequent-app.md](sequent-app.md) explains how the Mac app works;
this one is the same design, so read that first.

## What it is

`helper/linux/sequent` is one Python file, standard library only for the
work, so one package runs on any Debian or Ubuntu machine whatever its
processor, with no build. It does what Sequent.app does:

- it listens on the Pro DJ Link ports;
- it announces as player 7 on each link-local interface;
- it looks up rekordbox tracks in the decks' databases;
- it serves the page the same WebSocket on 127.0.0.1:8795.

Its `--selftest` must reproduce `tools/fixtures/selftest.expected`, as the Mac
app's does (`python3 tools/check_app.py helper/linux/sequent`). Its hello also
says `"platform": "linux"`, so the page calls it Sequent for Linux and never
offers it the Mac download.

The tray icon is GTK 3 and Ayatana AppIndicator, which the package
recommends. Without them, or with `--headless`, it runs in the terminal and
logs a line each time what it sees changes. Its menu is the Mac app's, less
the update check, since the releases are the Mac app's. Start at login
copies its desktop entry into `~/.config/autostart`.

What it leaves out: `--capture`, a Mac-side diagnostic, and telling rekordbox
apart from another copy when the ports are taken, since rekordbox doesn't run
on Linux.

## Building and checking

- `make deb` builds `build/Sequent-<version>.deb` with `tools/build_deb.py`,
  plain Python writing the ar and tar archives itself, so it builds the same
  on a Mac. A repeat build is byte-identical.
- `.github/workflows/linux.yml` builds it, installs it with apt on clean
  `debian:bookworm`, `debian:trixie` and `ubuntu:24.04`, and runs
  `tools/check_linux.sh`. That script checks five things on each image:
  - the self-test;
  - that it binds its ports, on moved ones;
  - the WebSocket's origin check;
  - that the tray starts under Xvfb with a session bus;
  - that no Python traceback appears.

  The workflow publishes nothing.
- A test build goes up as a GitHub pre-release by hand, so it is never the
  latest release the Mac app sees.

## Installing

```sh
curl -fLO https://github.com/turpin-studio/sequent-bridge/releases/download/<tag>/Sequent-<version>.deb
sudo apt install ./Sequent-<version>.deb
sequent &
```

On GNOME (Debian's default desktop) the tray needs the AppIndicator
extension: `sudo apt install gnome-shell-extension-appindicator`, then log
out and in. Ubuntu has it already. KDE, Cinnamon, MATE and Xfce need nothing.

## As a service

The package also installs a systemd service, off by default, which runs it
headless from boot with nobody logged in, for a machine that sits in the rig:

```sh
sudo systemctl enable --now sequent
journalctl -u sequent -f           # what it sees, a line per change
```

It runs as a throwaway user (`DynamicUser`) that can write nothing and see no
home directories, with no capabilities, IPv4 and netlink sockets only, since
nothing it does needs privilege. It holds the same ports as the tray icon, so
use one or the other: with the service running, the tray says another copy
holds the ports. Removing the package stops and disables it; an upgrade
restarts it if it was running. `linux.yml` checks all of that on a real
systemd, GitHub's Ubuntu runner.

## The one thing Linux needs that macOS doesn't

A CDJ-3000X's USB cable carries a network link, and **macOS gives it a
self-assigned 169.254 address by itself**. NetworkManager instead tries DHCP
on it, fails, and leaves it with no address. Sequent then sees beats but
can't announce, so it gets no status: no track, master or playing flags.
Tell NetworkManager to use a link-local address on that connection:

```sh
nmcli device                       # the CDJ is an ethernet device, enx…
nmcli connection add type ethernet ifname enx… con-name CDJ \
  ipv4.method link-local ipv6.method link-local
```

`ip -br addr` should then show a 169.254 address on it, and the tray's menu
lists the deck. A deck on an ordinary network with a DHCP router isn't
announced to, as with the Mac app.

A firewall (ufw, firewalld) has to let UDP 50000 to 50002 in.
