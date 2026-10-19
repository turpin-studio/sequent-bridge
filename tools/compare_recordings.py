"""Compare two recordings of Pro DJ Link traffic, packet type by packet type,
to see what a new firmware (or a different player) changed (make compare).

    python3 tools/compare_recordings.py OLD NEW

OLD and NEW are recording names in tools/recordings, as make record wrote
them (or a .pcap path). For each kind of packet (port and type byte) it says
whether both have it, their lengths, the firmware the players report, which
bytes ever change in each, and the bytes that stay fixed in both but differ
between them: a field moved or a flag changed meaning. Bytes that move in
either are left out of that last list, since a counter or a fader differing
says nothing; and unless both recordings played the same track, most of what
remains is the tracks' own data. Between two 1.40 recordings of different
tracks there were no new types or lengths, and about 150 such bytes. The packets are read as the replayer reads them.

Standard library only.
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import djlink_replay  # noqa: E402

TYPES = {
    (50000, 0x00): "channel claim 1", (50000, 0x02): "channel claim 2", (50000, 0x04): "channel claim final",
    (50000, 0x06): "keep-alive", (50000, 0x08): "channel conflict", (50000, 0x0a): "initial announcement",
    (50001, 0x0b): "absolute position", (50001, 0x26): "master handoff request", (50001, 0x27): "master handoff response",
    (50001, 0x28): "beat", (50002, 0x0a): "CDJ status", (50002, 0x29): "mixer status",
}


def load(name):
    path = pathlib.Path(name)
    if path.suffix == ".pcap" and path.exists():
        return djlink_replay.merge([djlink_replay.packets(path.read_bytes())])
    return djlink_replay.load(name)


def kinds(packets):
    """Per (port, type): lengths, the offsets that ever change, the first
    packet's bytes, and the firmware strings in its status."""
    out = {}
    for _, port, p in packets:
        if len(p) <= 0x0a:
            continue
        k = out.setdefault((port, p[0x0a]), {"count": 0, "lengths": set(), "first": p, "moves": set(), "firmware": set()})
        k["count"] += 1
        k["lengths"].add(len(p))
        first = k["first"]
        for i in range(max(len(first), len(p))):
            if i >= len(first) or i >= len(p) or first[i] != p[i]:
                k["moves"].add(i)
        if port == 50002 and p[0x0a] == 0x0a and len(p) >= 0x80:
            k["firmware"].add(p[0x7c:0x80].split(b"\0")[0].decode("ascii", "replace"))
    return out


def ranges(offsets):
    """0x26-0x2f style, for a list of offsets."""
    out, run = [], []
    for o in sorted(offsets):
        if run and o != run[-1] + 1:
            out.append(run)
            run = []
        run.append(o)
    if run:
        out.append(run)
    return ", ".join(f"0x{r[0]:02x}" if len(r) == 1 else f"0x{r[0]:02x}-0x{r[-1]:02x}" for r in out)


def compare(old, new, old_name="old", new_name="new"):
    a, b = kinds(old), kinds(new)
    lines = [f"{old_name}: {len(old)} packets; {new_name}: {len(new)} packets", ""]
    for key in sorted(set(a) | set(b)):
        name = TYPES.get(key, "not in the list")
        head = f"{key[0]} 0x{key[1]:02x} {name}"
        if key not in b:
            lines.append(f"{head}: only in {old_name} ({a[key]['count']})")
            continue
        if key not in a:
            lines.append(f"{head}: only in {new_name} ({b[key]['count']}), lengths {sorted(b[key]['lengths'])}")
            continue
        x, y = a[key], b[key]
        lines.append(f"{head}: {x['count']} / {y['count']}")
        if x["lengths"] != y["lengths"]:
            lines.append(f"  lengths: {sorted(x['lengths'])} / {sorted(y['lengths'])}")
        if x["firmware"] or y["firmware"]:
            lines.append(f"  firmware: {', '.join(sorted(x['firmware']))} / {', '.join(sorted(y['firmware']))}")
        only_new = y["moves"] - x["moves"]
        if only_new:
            lines.append(f"  moves only in {new_name}: {ranges(only_new)}")
        shared = min(len(x["first"]), len(y["first"]))
        fixed = [i for i in range(shared) if i not in x["moves"] and i not in y["moves"] and x["first"][i] != y["first"][i]]
        # The device's name and number differ between players; that's not news.
        fixed = [i for i in fixed if not (0x0b <= i < 0x20 or i in (0x21, 0x24))]
        # Mostly the tracks themselves (cue points, positions) unless both
        # recordings played the same one, so only the first few are listed.
        if fixed:
            shown = ", ".join(f"0x{i:02x} {x['first'][i]:02x}→{y['first'][i]:02x}" for i in fixed[:16])
            lines.append(f"  fixed in both, but different ({len(fixed)}): {shown}" + (", …" if len(fixed) > 16 else ""))
    return "\n".join(lines)


def main(argv):
    if len(argv) != 3:
        raise SystemExit("usage: compare_recordings.py OLD NEW")
    print(compare(load(argv[1]), load(argv[2]), argv[1], argv[2]))


if __name__ == "__main__":
    main(sys.argv)
