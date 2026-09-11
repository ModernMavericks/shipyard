#!/usr/bin/env python3
"""Fail when any FILE carries a piece of $SPARKLE_PRIVATE_KEY -- saying where, never what.

    SPARKLE_PRIVATE_KEY=... scan_for_key.py FILE...

Exit 0 when no file carries any, 1 when one does, 2 when it cannot look (no key, unreadable file).

GitHub masks the literal secret in a log, and nothing else: a trace, a slice, a hex dump or a
re-encoding goes out as-is, and a public repo's logs are public. So this looks for every 12-byte
window of the key's SECRET bytes -- as raw bytes, as hex in either case, and as standard and url-safe
base64 at each of the three byte alignments a slice can start on. Twelve bytes is 16 base64
characters: a leak that short is already a brute force away from the rest, and no honest file
contains 12 given random bytes by chance.

The secret bytes: the family's key is ed25519-keygen's 96-byte blob, private[64] || public[32].
Only private[64] is secret -- the public half is printed on purpose (assert_update_trusted.sh names
the keys it checks) and helps no one sign. A 32- or 64-byte key is secret throughout; anything else
(a format we do not know) is treated as secret text, character by character.

CI-only (scan-for-key.yml runs it on ubuntu), hence python3 -- doing this in shell would itself
expand the key into commands, which is the one thing it exists to forbid.
"""
import base64
import binascii
import os
import sys

WINDOW = 12  # bytes


def secret_bytes(raw):
    text = "".join(raw.split())
    try:
        blob = base64.b64decode(text, validate=True)
    except (binascii.Error, ValueError):
        return text.encode()
    if len(blob) == 96:
        return blob[:64]
    if len(blob) in (32, 64):
        return blob
    return text.encode()


def patterns(secret):
    """{pattern bytes: description}. Descriptions name an encoding and offset, never content."""
    pats = {}
    for i in range(len(secret) - WINDOW + 1):
        w = secret[i:i + WINDOW]
        pats.setdefault(w, "raw bytes")
        pats.setdefault(w.hex().encode(), "hex")
        pats.setdefault(w.hex().upper().encode(), "hex")
    chars = WINDOW * 4 // 3
    urlsafe = bytes.maketrans(b"+/", b"-_")
    for shift in range(3):
        # only the characters these bytes fully determine: a trailing partial group depends on
        # whatever followed the slice
        enc = base64.b64encode(secret[shift:])[: (len(secret) - shift) // 3 * 4]
        for j in range(len(enc) - chars + 1):
            w = enc[j:j + chars]
            pats.setdefault(w, "base64")
            pats.setdefault(w.translate(urlsafe), "url-safe base64")
    return pats


def main(argv):
    if not os.environ.get("SPARKLE_PRIVATE_KEY", "").strip() or len(argv) < 2:
        print("scan_for_key: usage: SPARKLE_PRIVATE_KEY=... scan_for_key.py FILE... "
              "(with no key there is nothing to look for, which is not a pass)", file=sys.stderr)
        return 2
    pats = patterns(secret_bytes(os.environ["SPARKLE_PRIVATE_KEY"]))
    found = False
    for path in argv[1:]:
        try:
            with open(path, "rb") as f:
                data = f.read()
        except OSError as e:
            print("scan_for_key: cannot read %s: %s" % (path, e.strerror), file=sys.stderr)
            return 2
        hits = set()
        for pat, what in pats.items():
            at = data.find(pat)
            while at >= 0:
                hits.add((data.count(b"\n", 0, at) + 1, what))
                at = data.find(pat, at + 1)
        for line, what in sorted(hits)[:50]:
            print("%s:%d: a piece of the signing key, as %s" % (path, line, what))
        found = found or bool(hits)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
