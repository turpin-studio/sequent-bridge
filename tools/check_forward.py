"""Check a built Sequent.app reads a phone's forwarded packets and works out
how they travel, without a phone (the iPhone app's Forwarder passes the
decks on over Wi-Fi; docs/sequent-app.md, "Passed on by a phone").

`--selftest-forward` reads a forwarded beat (port, the deck's address, when
the phone heard it, the packet), refuses what isn't one, and prints the
delay figures (baseline, typical and 95th percentile behind it) for fixed
delays. tools/fixtures/forward.expected holds what that must be, worked out
by hand when it was made. Run it with

    make app && python3 tools/check_forward.py build/Sequent.app
"""
import pathlib
import subprocess
import sys

EXPECTED = (pathlib.Path(__file__).parent / "fixtures" / "forward.expected").read_text().splitlines()


def main(app):
    binary = pathlib.Path(app)
    if binary.is_dir():
        binary = binary / "Contents" / "MacOS" / "Sequent"
    out = subprocess.run([str(binary), "--selftest-forward"], capture_output=True, text=True, check=True, timeout=30).stdout.splitlines()
    if out != EXPECTED:
        sys.exit("--selftest-forward differs:\n" + "\n".join(f"  got  {g}\n  want {w}" for g, w in zip(out + [""] * 9, EXPECTED + [""] * 9) if g != w))
    print("ok: forwarded packets read, others refused, and the delay figures as expected")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "build/Sequent.app")
