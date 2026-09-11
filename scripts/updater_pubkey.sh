#!/bin/sh
# Print the SUPublicEDKey and SUFeedURL of the Sparkle updater a .pkg installs -- what a fresh install
# of it will trust, and where it will look for its next update:
#
#   updater_pubkey.sh PKG   ->   SUPublicEDKey=<base64>
#                                SUFeedURL=<url>
#
# Read from the updater app's own Info.plist inside the payload, not from the repo that built it:
# products configure the key differently (updater/ed25519_key.pub, updater/updater/ed25519_key.pub,
# ED_PUBKEY inline in CMake), and the pkg is what users actually install.
#
# Several updaters (shipyard's own pkg carries one per arch slice) are fine when they agree. When
# they disagree, which one a client runs is not ours to guess, so this fails; so does a pkg with no
# updater at all. Exit 0 with an answer, 1 without one, 2 on usage.
#
# Runs on 10.9 as well as in CI: `pkgutil --expand` (10.9's pkgutil has no --expand-full) and the
# gzip'd cpio Payload that pkgbuild writes on both.
set -eu
[ "$#" -eq 1 ] || { echo "usage: updater_pubkey.sh PKG" >&2; exit 2; }
PKG="$1"
T="$(mktemp -d "${TMPDIR:-/tmp}/updater_pubkey.XXXXXX")"; trap 'rm -rf "$T"' EXIT

pkgutil --expand "$PKG" "$T/x" >/dev/null 2>&1 \
  || { echo "updater_pubkey: cannot expand $PKG as a pkg" >&2; exit 1; }
mkdir "$T/p"
# Only the apps' Info.plists come out of each payload, however large the payload is.
find "$T/x" -type f -name Payload | while IFS= read -r payload; do
  ( cd "$T/p" && gunzip -c "$payload" | cpio -id '*.app/Contents/Info.plist' 2>/dev/null ) \
    || { echo "updater_pubkey: cannot read the payload $payload" >&2; exit 1; }
done

# One "key<TAB>feed" line per distinct updater.
pairs="$(find "$T/p" -type f -path '*.app/Contents/Info.plist' | while IFS= read -r plist; do
  key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$plist" 2>/dev/null)" || continue
  feed="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$plist" 2>/dev/null)" || feed=
  printf '%s\t%s\n' "$key" "$feed"
done | sort -u)"

case "$(printf '%s' "$pairs" | grep -c .)" in
  0) echo "updater_pubkey: no Sparkle updater (no app with SUPublicEDKey) in $PKG" >&2; exit 1 ;;
  1) printf '%s\n' "$pairs" | sed 's/^\([^	]*\)	\(.*\)$/SUPublicEDKey=\1\
SUFeedURL=\2/' ;;
  *) echo "updater_pubkey: the updaters in $PKG disagree about their key or feed:" >&2
     printf '%s\n' "$pairs" | sed 's/^/  /' >&2
     exit 1 ;;
esac
