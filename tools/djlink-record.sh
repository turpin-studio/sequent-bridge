#!/bin/sh
# Record the CDJs' Pro DJ Link traffic, to play back later with
# tools/djlink_replay.py and test the page with no decks (make record).
#
#   tools/djlink-record.sh NAME [SECONDS]
#
# Sequent.app must be running, or the players send no status: they send it
# only to devices that have announced, and the app announces as player 7.
#
# It records every wired link that could reach a deck (a USB cable to a CDJ,
# a USB or Thunderbolt Ethernet adapter), not the one carrying the internet,
# whether or not it has an address yet: a deck's link has none for its first
# minute, while macOS waits for a DHCP server before taking a 169.254 one, and
# a deck's boot happens in that minute. IFACES="en8 en5" names them instead.
#
# Each link is followed: a deck restarting takes its USB link away and brings
# it back as a new interface, which ends a capture, so recording starts again
# as soon as it's back, in a numbered part. Every file is NAME-<interface>
# [-<part>].pcap in tools/recordings, written as packets arrive; the replayer
# merges them and drops the copies, as the app does. All UDP is kept (a boot's
# DHCP and announcements) and the database's TCP port. Needs packet capture
# rights, which Wireshark's ChmodBPF gives without sudo.
set -eu
name=${1:?usage: djlink-record.sh NAME [SECONDS]}
seconds=${2:-120}
dir=$(cd "$(dirname "$0")" && pwd)/recordings
mkdir -p "$dir"
filter='udp or tcp port 12523'

# The wired ports, by macOS's own names for them, less the one the default
# route uses, and any link already on 169.254.
internet=$(route -n get default 2>/dev/null | awk '/interface:/ { print $2 }')
wired=$(networksetup -listallhardwareports 2>/dev/null | awk '
  /^Hardware Port:/ { port = $0 }
  /^Device:/ && port ~ /(USB|Ethernet|LAN)/ && port !~ /Bridge/ { print $2 }')
linklocal=$(ifconfig | awk '/^[a-z]/ { i = $1; sub(":", "", i) } /inet 169\.254\./ { print i }')
links=${IFACES:-$(printf '%s\n' $wired $linklocal | grep -vx "${internet:-none}" | sort -u)}
[ -n "$links" ] || { echo "No wired link to record: connect a CDJ by USB or Ethernet, or name one with IFACES=."; exit 1; }
pgrep -f 'Sequent.app/Contents/MacOS/Sequent' >/dev/null || echo "Sequent.app isn't running: the decks will send beats but no status."

end=$(( $(date +%s) + seconds ))
state=$(mktemp -d)
trap 'touch "$state/stop"; for p in "$state"/*.pid; do [ -f "$p" ] && kill "$(cat "$p")" 2>/dev/null; done' INT TERM

# One link: capture while it's there, and again each time it comes back.
follow() {
  i=$1 n=0
  while [ "$(date +%s)" -lt "$end" ] && [ ! -f "$state/stop" ]; do
    if ifconfig "$i" 2>/dev/null | grep -q "status: active"; then
      n=$((n + 1))
      f="$dir/$name-$i.pcap"; [ "$n" -gt 1 ] && f="$dir/$name-$i-$n.pcap"
      echo "$(date +%T) recording $i to tools/recordings/$(basename "$f")"
      tcpdump -U -i "$i" -n -q -w "$f" "$filter" 2>/dev/null &
      echo $! > "$state/$i.pid"
      wait $! 2>/dev/null || true
      rm -f "$state/$i.pid"
      [ "$(date +%s)" -lt "$end" ] && [ ! -f "$state/stop" ] && echo "$(date +%T) $i went away; waiting for it to come back"
    else
      sleep 0.2
    fi
  done
}

for i in $links; do follow "$i" & done
echo "Waiting on: $(echo $links). For $seconds seconds: power the decks on, play, change tracks, stop and start, move the tempo."
while [ "$(date +%s)" -lt "$end" ] && [ ! -f "$state/stop" ]; do sleep 1; done
touch "$state/stop"
for p in "$state"/*.pid; do [ -f "$p" ] && kill "$(cat "$p")" 2>/dev/null; done
wait 2>/dev/null || true
rm -rf "$state"
for f in "$dir/$name"-*.pcap; do
  [ -f "$f" ] && echo "$(tcpdump -r "$f" 2>/dev/null | wc -l | tr -d ' ') packets in $(basename "$f")"
done
echo "Play it back with: make replay FILE=$name"
