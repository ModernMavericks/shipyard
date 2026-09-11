#!/bin/sh
# Sign a .pkg with the native EdDSA signer and emit its Sparkle appcast.xml to stdout, in one call.
# Generalized from the near-identical CI blocks in mavericks-golang and mavericks-swift, which each
# ran `sign_update -s $KEY $pkg` then piped the enclosure string into gen_appcast.sh by hand.
#
# Usage (SPARKLE_PRIVATE_KEY must be in the environment):
#   sign_and_appcast.sh --channel-title T --version V --pkg-url URL \
#     --notes-file FILE --pkg PKG [--signer BIN] [--min-os 10.9.5]  > appcast.xml
#
#   --signer   the ed25519-sign binary; OPTIONAL -- defaults to the prebuilt ed25519-sign fetched from
#              the latest mavericks-ed25519 release (needs gh). Pass a path to use a specific one.
#   --pkg      the .pkg to sign
#   --pkg-url  the URL the enclosure will point at (the release-asset download URL)
#   others     passed through to gen_appcast.sh
#
# The private key is read from $SPARKLE_PRIVATE_KEY and reaches the signer only on its stdin, via
# `printenv SPARKLE_PRIVATE_KEY |`: this script never lets the shell expand the key into a command.
# That keeps it out of the signer's argv (visible to anything that can list processes) and out of
# `sh -x` traces, which print every expanded command -- GitHub masks the literal secret in a log,
# but nothing masks what a trace or a re-encoding prints. tests/sign_and_appcast_key.bats runs this
# under `sh -x` and fails on any piece of the key in the output. Until this used printenv, the key
# was an argv here (behind a comment claiming it never was), and even the "is it set?" test below
# printed it under a trace.
set -eu
SELF="$(cd "$(dirname "$0")" && pwd)"

SIGNER=""; CHANNEL=""; VER=""; URL=""; NOTES=""; PKG=""; MINOS="${MAVERICKS_MIN_OS:-10.9.5}"
while [ $# -gt 0 ]; do
  case "$1" in
    --signer) SIGNER="$2"; shift 2;;
    --channel-title) CHANNEL="$2"; shift 2;;
    --version) VER="$2"; shift 2;;
    --pkg-url) URL="$2"; shift 2;;
    --notes-file) NOTES="$2"; shift 2;;
    --pkg) PKG="$2"; shift 2;;
    --min-os) MINOS="$2"; shift 2;;
    *) echo "sign_and_appcast: unknown arg: $1" >&2; exit 2;;
  esac
done
[ -n "$CHANNEL" ] && [ -n "$VER" ] && [ -n "$URL" ] && [ -n "$NOTES" ] && [ -n "$PKG" ] \
  || { echo "sign_and_appcast: need --channel-title --version --pkg-url --notes-file --pkg" >&2; exit 2; }
[ -f "$PKG" ] || { echo "sign_and_appcast: no pkg: $PKG" >&2; exit 1; }
# grep -q . reads the key without printing it, and fails on unset (printenv) and empty (grep) alike.
printenv SPARKLE_PRIVATE_KEY | grep -q . \
  || { echo "sign_and_appcast: SPARKLE_PRIVATE_KEY not set" >&2; exit 1; }

# --signer is optional: default to the prebuilt ed25519-sign from the latest mavericks-ed25519 release.
# (ed25519 signatures are standard + deterministic, so the tool version doesn't change the output.)
if [ -z "$SIGNER" ]; then
  command -v gh >/dev/null 2>&1 || { echo "sign_and_appcast: no --signer, and gh unavailable to fetch ed25519-sign" >&2; exit 1; }
  # gh must be authenticated or the releases API call is anonymous (60 req/hr) and 403s under CI load.
  # In a workflow, export GH_TOKEN: ${{ github.token }} on this step (public cross-repo read still works).
  if [ -z "${GH_TOKEN:-}" ] && [ -z "${GITHUB_TOKEN:-}" ] && ! gh auth status >/dev/null 2>&1; then
    echo "sign_and_appcast: gh is unauthenticated; set GH_TOKEN (e.g. GH_TOKEN: \${{ github.token }}) so the ed25519-sign fetch isn't rate-limited" >&2
    exit 1
  fi
  _dl=$(mktemp -d "${TMPDIR:-/tmp}/sign_and_appcast.XXXXXX")
  gh release download -R ModernMavericks/ed25519 -p '*.pkg' -D "$_dl" \
    || { echo "sign_and_appcast: could not download the ed25519 .pkg from mavericks-ed25519 releases (is GH_TOKEN set on this step?)" >&2; exit 1; }
  pkgutil --expand-full "$_dl"/*.pkg "$_dl/x" \
    || { echo "sign_and_appcast: could not expand the ed25519 .pkg" >&2; exit 1; }
  SIGNER=$(find "$_dl/x" -type f -name ed25519-sign | head -1)
  [ -n "$SIGNER" ] && chmod +x "$SIGNER"
fi
[ -x "$SIGNER" ] || { echo "sign_and_appcast: signer not executable: $SIGNER" >&2; exit 1; }

# ed25519-sign (-f - <pkg>: key on stdin) prints the bare base64 signature; assemble the Sparkle
# enclosure attrs (edSignature + length) from it and the pkg's byte size.
SIG=$(printenv SPARKLE_PRIVATE_KEY | "$SIGNER" -f - "$PKG")
[ -n "$SIG" ] || { echo "sign_and_appcast: signer produced no signature" >&2; exit 1; }
LEN=$(wc -c < "$PKG" | tr -d '[:space:]')
ENC="sparkle:edSignature=\"$SIG\" length=\"$LEN\""

# gen_appcast.sh is the pure-text appcast renderer (needs no key); it lives beside this script.
sh "$SELF/gen_appcast.sh" "$CHANNEL" "$VER" "$URL" "$MINOS" "$NOTES" "$ENC"
