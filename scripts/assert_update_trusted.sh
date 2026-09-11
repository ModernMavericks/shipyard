#!/bin/sh
# Prove the clients ALREADY INSTALLED will accept a signed pkg -- before its appcast is published.
#
#   assert_update_trusted.sh --pkg PKG --signature SIG --verifier ED25519_VERIFY
#                            [--pubkey B64] [--allow-key-change]
#
# A Sparkle client verifies the appcast's sparkle:edSignature against the SUPublicEDKey of the
# updater it HAS, which came from the pkg the feed offered last time -- not the repo's .pub, and not
# the key the new pkg ships. So: read SUFeedURL from the new pkg's updater, fetch that live feed (still
# the previous release, since this one is not published yet), take its enclosure pkg, read ITS
# updater's key, and verify SIG over PKG against that. ed25519-sign's own self-check cannot: it checks
# against the public half of whatever key it was handed, so a SPARKLE_PRIVATE_KEY that does not match
# the shipped updater signs "successfully" and every installed client rejects the update.
#
#   - No live feed yet (HTTP 404, or a file:// that is not there): a first release. Nothing is
#     installed, so the key to satisfy is the one this pkg ships -- still checked, which catches a
#     secret that does not match the updater before anyone installs it.
#   - A feed that cannot be READ is not a feed that does not exist: fail closed, rather than guess
#     "first release" and wave through exactly the key change this exists to catch.
#   - The new pkg ships a different key than the live one, signed by the live one: a bridge release.
#     Trusted, with a notice that the NEXT release must be signed by the new key.
#   - --allow-key-change: a deliberate hard switch that installed clients will NOT follow. The
#     signature must then verify against the new key. Say why in the workflow that passes it.
#   - --pubkey B64: the pkg installs no updater; name the key installed clients trust yourself.
#
# Messages go to stderr (sign_and_appcast.sh's stdout is the appcast). Exit 0 trusted, 1 not, 2 usage.
set -eu
SELF="$(cd "$(dirname "$0")" && pwd)"

PKG=""; SIG=""; VERIFIER=""; PUBKEY=""; ALLOW_CHANGE=no
while [ $# -gt 0 ]; do
  case "$1" in
    --pkg) PKG="$2"; shift 2;;
    --signature) SIG="$2"; shift 2;;
    --verifier) VERIFIER="$2"; shift 2;;
    --pubkey) PUBKEY="$2"; shift 2;;
    --allow-key-change) ALLOW_CHANGE=yes; shift;;
    *) echo "assert_update_trusted: unknown arg: $1" >&2; exit 2;;
  esac
done
[ -n "$PKG" ] && [ -n "$SIG" ] && [ -n "$VERIFIER" ] \
  || { echo "assert_update_trusted: need --pkg --signature --verifier" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/assert_update_trusted.XXXXXX")"; trap 'rm -rf "$T"' EXIT
say() { echo "assert_update_trusted: $*" >&2; }
field() { sed -n "s/^$1=//p" "$2"; }
# Status 0 when SIG over PKG verifies against KEY, 1 when it does not. An ed25519-verify that cannot
# check at all (exit 2: a malformed key or signature) is neither answer, so that ends the run.
verifies() {
  set +e; "$VERIFIER" -p "$1" "$PKG" "$SIG" >/dev/null 2>"$T/verify.err"; rc=$?; set -e
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) say "could not check the signature (ed25519-verify exit $rc): $(cat "$T/verify.err")"; exit 1 ;;
  esac
}

if [ -n "$PUBKEY" ]; then
  verifies "$PUBKEY" && { say "ok -- signed by $PUBKEY, the key named by --pubkey"; exit 0; }
  say "the signature does not verify against $PUBKEY, the key named by --pubkey"
  exit 1
fi

sh "$SELF/updater_pubkey.sh" "$PKG" > "$T/new" \
  || { say "$PKG has no readable Sparkle updater -- pass --pubkey <the key installed clients trust>"; exit 1; }
NEW_KEY="$(field SUPublicEDKey "$T/new")"
FEED="$(field SUFeedURL "$T/new")"
[ -n "$FEED" ] || { say "the updater in $PKG names no SUFeedURL, so there is no live release to ask"; exit 1; }

# Not -f: a 404 is an answer ("no feed yet"), not a failure. curl reports HTTP 000 for file://.
set +e
code="$(curl -sSL -o "$T/feed.xml" -w '%{http_code}' "$FEED" 2>"$T/curl.err")"; rc=$?
set -e
if { [ "$rc" -eq 0 ] && [ "$code" = 404 ]; } || [ "$rc" -eq 37 ]; then
  verifies "$NEW_KEY" && {
    say "ok -- first release (no live feed at $FEED): signed by $NEW_KEY, the key this pkg's updater ships"
    exit 0
  }
  say "first release, and the signature does not verify against $NEW_KEY -- the key this pkg's updater ships."
  say "SPARKLE_PRIVATE_KEY is not its private half, so every install would reject every update signed with it."
  exit 1
fi
if [ "$rc" -ne 0 ] || { [ "$code" != 200 ] && [ "$code" != 000 ]; }; then
  say "cannot read the live feed $FEED (curl exit $rc, HTTP $code): $(cat "$T/curl.err")"
  say "refusing to guess which key installed clients trust"
  exit 1
fi

URL="$(sed -n 's/.*<enclosure[^>]* url="\([^"]*\)".*/\1/p' "$T/feed.xml" | head -1)"
[ -n "$URL" ] || { say "the live feed $FEED offers no enclosure -- cannot tell which key installed clients trust"; exit 1; }
curl -fsSL -o "$T/live.pkg" "$URL" 2>"$T/curl.err" \
  || { say "cannot download the live release's pkg $URL: $(cat "$T/curl.err")"; exit 1; }
sh "$SELF/updater_pubkey.sh" "$T/live.pkg" > "$T/live" \
  || { say "the live release's pkg ($URL) has no readable Sparkle updater"; exit 1; }
LIVE_KEY="$(field SUPublicEDKey "$T/live")"

if verifies "$LIVE_KEY"; then
  if [ "$NEW_KEY" = "$LIVE_KEY" ]; then
    say "ok -- signed by $LIVE_KEY, the key installed updaters trust"
  else
    say "ok -- signed by $LIVE_KEY, the key installed updaters trust. This release moves them to $NEW_KEY:"
    say "sign the next release with ITS private key (change SPARKLE_PRIVATE_KEY once this one is published)"
  fi
  exit 0
fi
if [ "$ALLOW_CHANGE" = yes ]; then
  verifies "$NEW_KEY" \
    || { say "--allow-key-change, but the signature does not verify against $NEW_KEY (this pkg's key) either"; exit 1; }
  say "WARNING (--allow-key-change): signed by $NEW_KEY; clients on the live release trust $LIVE_KEY"
  say "and will not accept this update"
  exit 0
fi
say "installed updaters trust $LIVE_KEY (from the live release's pkg, $URL), and this signature does not"
say "verify against it: they would reject this update. Sign with that key; to move them to a new key,"
say "ship the new key in a release signed by the old one (a bridge); to abandon them, --allow-key-change."
exit 1
