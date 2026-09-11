bats_require_minimum_version 1.5.0
load lib/sparkle_pkg

# assert_update_trusted.sh: will the clients ALREADY INSTALLED accept this signed pkg? They verify
# the appcast's signature against the SUPublicEDKey of the updater they have -- the one in the pkg
# the live feed currently offers -- not against the repo's .pub, and not against the key the new pkg
# ships. Feeds and enclosures are file:// URLs here; the verifier is ed25519-verify's contract.
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  T="$BATS_TEST_TMPDIR"
  KOLD='b2xkLWtleS1vbGQta2V5LW9sZC1rZXktb2xkLWtleS0='
  KNEW='bmV3LWtleS1uZXcta2V5LW5ldy1rZXktbmV3LWtleS0='
  KOTHER='b3RoZXIta2V5LW90aGVyLWtleS1vdGhlci1rZXktb3Q='
  FEED="file://$T/appcast.xml"
  mkverifier "$T/verify"
}

trusted() {  # PKG SIGNATURE [extra args]
  local pkg="$1" sig="$2"; shift 2
  sh "$ROOT/scripts/assert_update_trusted.sh" --pkg "$pkg" --signature "$sig" --verifier "$T/verify" "$@"
}
# The live release: its pkg's updater trusts KEY, and the feed offers it.
live_release() {  # KEY
  mkpkg "$T/prev.pkg" "$1" "$FEED" TestUpdater
  mkfeed "$T/appcast.xml" "file://$T/prev.pkg"
}

@test "first release (no live feed yet): signed by the key the new updater ships -> trusted" {
  mkpkg "$T/new.pkg" "$KNEW" "$FEED" TestUpdater
  run --separate-stderr trusted "$T/new.pkg" "signed-by:$KNEW"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"first release"* ]] || false
  [ -z "$output" ]
}

@test "first release: signed by any other key -> refused, the secret does not match the updater" {
  mkpkg "$T/new.pkg" "$KNEW" "$FEED" TestUpdater
  run --separate-stderr trusted "$T/new.pkg" "signed-by:$KOTHER"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"$KNEW"* ]] || false
}

@test "steady state: signed by the key installed updaters trust -> trusted" {
  live_release "$KOLD"
  mkpkg "$T/new.pkg" "$KOLD" "$FEED" TestUpdater
  run --separate-stderr trusted "$T/new.pkg" "signed-by:$KOLD"
  [ "$status" -eq 0 ]
}

@test "a key change with no bridge release -> refused, installed clients still trust the old key" {
  live_release "$KOLD"
  mkpkg "$T/new.pkg" "$KNEW" "$FEED" TestUpdater
  run --separate-stderr trusted "$T/new.pkg" "signed-by:$KNEW"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"$KOLD"* ]] || false
}

@test "a bridge release (signed by the old key, shipping a new one) -> trusted, and says what's next" {
  live_release "$KOLD"
  mkpkg "$T/new.pkg" "$KNEW" "$FEED" TestUpdater
  run --separate-stderr trusted "$T/new.pkg" "signed-by:$KOLD"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"$KNEW"* ]] || false
  [[ "$stderr" == *"next release"* ]] || false
}

@test "--allow-key-change lets a hard key change through, signed by the new key and nothing else" {
  live_release "$KOLD"
  mkpkg "$T/new.pkg" "$KNEW" "$FEED" TestUpdater
  run --separate-stderr trusted "$T/new.pkg" "signed-by:$KNEW" --allow-key-change
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"will not accept"* ]] || false
  run --separate-stderr trusted "$T/new.pkg" "signed-by:$KOTHER" --allow-key-change
  [ "$status" -eq 1 ]
}

@test "a pkg with no updater is refused, unless --pubkey names the key clients trust" {
  mkpkg "$T/new.pkg"
  run --separate-stderr trusted "$T/new.pkg" "signed-by:$KOLD"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"--pubkey"* ]] || false
  run --separate-stderr trusted "$T/new.pkg" "signed-by:$KOLD" --pubkey "$KOLD"
  [ "$status" -eq 0 ]
  run --separate-stderr trusted "$T/new.pkg" "signed-by:$KOTHER" --pubkey "$KOLD"
  [ "$status" -eq 1 ]
}

# Not being able to see the live release is not the same as there being none: guessing "first
# release" here would wave through exactly the key change this exists to catch.
@test "a feed that cannot be read (as opposed to one that does not exist) fails closed" {
  mkpkg "$T/new.pkg" "$KNEW" "http://127.0.0.1:9/appcast.xml" TestUpdater
  run --separate-stderr trusted "$T/new.pkg" "signed-by:$KNEW"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"cannot read"* ]] || false
}

@test "a live feed that offers no enclosure fails closed" {
  printf '<rss><channel><item></item></channel></rss>\n' > "$T/appcast.xml"
  mkpkg "$T/new.pkg" "$KNEW" "$FEED" TestUpdater
  run --separate-stderr trusted "$T/new.pkg" "signed-by:$KNEW"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"enclosure"* ]] || false
}

@test "requires --pkg, --signature and --verifier" {
  mkpkg "$T/new.pkg" "$KNEW" "$FEED" TestUpdater
  run --separate-stderr sh "$ROOT/scripts/assert_update_trusted.sh" --pkg "$T/new.pkg" --signature x
  [ "$status" -eq 2 ]
}
