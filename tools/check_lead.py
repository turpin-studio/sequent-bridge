"""Check a built Sequent.app leads the decks as it should, without any decks.

Leading is Sequent taking the tempo master role while the page carries on
after the decks stop (docs/sequent-app.md, "Leading"). Its decisions live in
Leader, apart from the sockets, and `--selftest-lead` runs Leader through its
cases with made-up decks, printing what it would send: whom it announces as,
its status (master, playing, synced, the handoff byte, the sync counter), its
beats, and the handoff packets, in hex after the 0x1f-byte header. Last it
decodes its own status and beat packets with the decoder that reads the real
decks, so the offsets they're written at are checked against it.

tools/fixtures/lead.expected holds what that must be. It was checked line by
line against Deep Symmetry's sync notes and beat-link's VirtualCdj when it was
made, and has not yet run against real decks. Run it with

    make app && python3 tools/check_lead.py build/Sequent.app

Only the Mac app leads, so far; the Linux bridge ignores the page's `lead`.
"""
import json
import pathlib
import subprocess
import sys

EXPECTED = (pathlib.Path(__file__).parent / "fixtures" / "lead.expected").read_text().splitlines()


def same(got, want):
    if got.startswith("{"):
        try:
            return json.loads(got) == json.loads(want)
        except ValueError:
            pass
    return got == want


def main(app):
    binary = pathlib.Path(app)
    if binary.is_dir():
        binary = binary / "Contents" / "MacOS" / "Sequent"
    out = subprocess.run([str(binary), "--selftest-lead"], capture_output=True, text=True, check=True, timeout=30).stdout.splitlines()
    if len(out) != len(EXPECTED):
        sys.exit(f"expected {len(EXPECTED)} lines from --selftest-lead, got {len(out)}:\n" + "\n".join(out))
    failures = [f"line {i + 1}:\n  got  {got}\n  want {want}" for i, (got, want) in enumerate(zip(out, EXPECTED)) if not same(got, want)]
    if failures:
        sys.exit("\n".join(failures))
    print(f"ok: leading made the {sum(1 for l in EXPECTED if l.startswith('# ')) - 1} cases' packets as expected, and they decode")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "build/Sequent.app")
