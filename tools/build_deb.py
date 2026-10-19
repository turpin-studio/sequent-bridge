"""Build the Linux helper's Debian package, Sequent-<version>.deb.

    python3 tools/build_deb.py VERSION OUT.deb      (or: make deb)

Written out by hand rather than with dpkg-deb, so it builds the same on a Mac
as on Linux: a .deb is an ar archive of debian-binary, control.tar.xz and
data.tar.xz. Every file is owned by root with a fixed time, so the same
source and version give the same bytes. The pipeline (.github/workflows/
linux.yml) installs the result with apt in clean Debian and Ubuntu images
and runs it there, which is the check that dpkg agrees.

VERSION is the program's own, such as 0.3.0 or 0.0.0-dev.270. Debian's
version puts a development suffix after a tilde, so it sorts before the
release it leads to.
"""
import hashlib
import io
import pathlib
import re
import sys
import tarfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
LINUX = ROOT / "helper" / "linux"
MTIME = 1767225600   # 1 January 2026: any fixed time, for repeatable builds


def files(version):
    """{path in the package: (bytes, mode)}"""
    program = (LINUX / "sequent").read_text()
    program, stamped = re.subn(r'^VERSION = "[^"]*"$', f'VERSION = "{version}"', program, flags=re.M)
    assert stamped == 1, "no VERSION line to stamp"
    out = {
        "usr/bin/sequent": (program.encode(), 0o755),
        "usr/share/applications/sequent.desktop": ((LINUX / "sequent.desktop").read_bytes(), 0o644),
        "usr/lib/systemd/system/sequent.service": ((LINUX / "sequent.service").read_bytes(), 0o644),
        "usr/share/icons/hicolor/scalable/apps/sequent.svg": ((ROOT / "helper" / "icon.svg").read_bytes(), 0o644),
        "usr/share/icons/hicolor/512x512/apps/sequent.png": ((ROOT / "helper" / "icon-512.png").read_bytes(), 0o644),
        "usr/share/doc/sequent/copyright": (COPYRIGHT.encode(), 0o644),
    }
    for icon in sorted((LINUX / "icons").glob("*.svg")):
        out[f"usr/share/sequent/icons/{icon.name}"] = (icon.read_bytes(), 0o644)
    return out


# The service ships off: these only tell systemd it's there, restart it on
# an upgrade if it was running, and stop and disable it on removal.
POSTINST = """#!/bin/sh
set -e
if [ -d /run/systemd/system ]; then
  systemctl daemon-reload || true
  [ "$1" = configure ] && [ -n "$2" ] && systemctl try-restart sequent.service || true
fi
"""
PRERM = """#!/bin/sh
set -e
if [ "$1" = remove ] && [ -d /run/systemd/system ]; then
  systemctl disable --now sequent.service || true
fi
"""
POSTRM = """#!/bin/sh
set -e
if [ -d /run/systemd/system ]; then systemctl daemon-reload || true; fi
"""

COPYRIGHT = """Sequent, the Pro DJ Link connection for turpin.studio.
Copyright 2026 Dean Turpin <hello@turpin.dev>. All rights reserved.

Sequent took inspiration from the amazing work carried out by Deep Symmetry.
Its Pro DJ Link decoding follows their DJ Link packet analysis,
https://djl-analysis.deepsymmetry.org/
"""


def control(version, size_kb):
    return f"""Package: sequent
Version: {version.replace("-", "~", 1)}
Architecture: all
Maintainer: Dean Turpin <hello@turpin.dev>
Installed-Size: {size_kb}
Depends: python3 (>= 3.9), iproute2
Recommends: python3-gi, gir1.2-gtk-3.0, gir1.2-ayatanaappindicator3-0.1, xdg-utils
Suggests: gnome-shell-extension-appindicator
Section: sound
Priority: optional
Homepage: https://turpin.studio/
Description: connects Pioneer CDJs to the Sequent page at turpin.studio
 Listens for the CDJs on Pro DJ Link, over their USB cables or a network,
 and hands their tempo, beats, key and status to the Sequent page in the
 browser, so its instruments play along with the decks. Lives in the tray;
 run it with --headless for none.
"""


def tar(entries):
    """An xz tar of {path: (bytes, mode)}, with its directories, root-owned."""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:xz", format=tarfile.GNU_FORMAT) as t:
        dirs = sorted({str(p) for path in entries for p in pathlib.PurePosixPath(path).parents if str(p) != "."})
        for d in dirs:
            info = tarfile.TarInfo(f"./{d}/")
            info.type, info.mode, info.mtime = tarfile.DIRTYPE, 0o755, MTIME
            t.addfile(info)
        for path in sorted(entries):
            data, mode = entries[path]
            info = tarfile.TarInfo(f"./{path}")
            info.size, info.mode, info.mtime = len(data), mode, MTIME
            t.addfile(info, io.BytesIO(data))
    return buf.getvalue()


def ar(members):
    out = b"!<arch>\n"
    for name, data in members:
        out += f"{name:<16}{MTIME:<12}{0:<6}{0:<6}{'100644':<8}{len(data):<10}`\n".encode() + data
        if len(data) % 2:
            out += b"\n"
    return out


def build(version):
    data = files(version)
    size_kb = sum(len(d) for d, _ in data.values()) // 1024 + 1
    md5sums = "".join(f"{hashlib.md5(d).hexdigest()}  {p}\n" for p, (d, _) in sorted(data.items()))
    meta = {"control": (control(version, size_kb).encode(), 0o644), "md5sums": (md5sums.encode(), 0o644),
            "postinst": (POSTINST.encode(), 0o755), "prerm": (PRERM.encode(), 0o755), "postrm": (POSTRM.encode(), 0o755)}
    return ar([("debian-binary", b"2.0\n"), ("control.tar.xz", tar(meta)), ("data.tar.xz", tar(data))])


if __name__ == "__main__":
    if len(sys.argv) != 3 or not re.fullmatch(r"\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?", sys.argv[1]):
        sys.exit("usage: build_deb.py X.Y.Z[-suffix] OUT.deb")
    out = pathlib.Path(sys.argv[2])
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(build(sys.argv[1]))
    print(f"Built {out}")
