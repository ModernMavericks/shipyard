bats_require_minimum_version 1.5.0
load lib/sparkle_pkg

# sign_and_appcast.sh publishes no appcast that installed clients would reject: after signing it runs
# assert_update_trusted.sh (whose cases are tests/assert_update_trusted.bats) and stops on a refusal.
# Stubs stand in for ed25519-sign and ed25519-verify, side by side as the ed25519 release ships them.
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  T="$BATS_TEST_TMPDIR"
  KNEW='bmV3LWtleS1uZXcta2V5LW5ldy1rZXktbmV3LWtleS0='
  KOTHER='b3RoZXIta2V5LW90aGVyLWtleS1vdGhlci1rZXktb3Q='
  mkdir -p "$T/bin"
  mkverifier "$T/bin/ed25519-verify"
  printf '## Notes\n\n- thing\n' > "$T/notes.md"
}

signer_signs_as() {  # KEY -- the stub signer's signature "verifies" against KEY
  printf '#!/bin/sh\ncat >/dev/null\necho "signed-by:%s"\n' "$1" > "$T/bin/ed25519-sign"
  chmod +x "$T/bin/ed25519-sign"
}

sign_and_appcast() {
  SPARKLE_PRIVATE_KEY=throwaway sh "$ROOT/scripts/sign_and_appcast.sh" --signer "$T/bin/ed25519-sign" \
    --channel-title C --version 1.2.3 --pkg-url https://example.invalid/new.pkg \
    --notes-file "$T/notes.md" --pkg "$T/new.pkg" "$@"
}

@test "a signature installed clients will accept gets its appcast" {
  mkpkg "$T/new.pkg" "$KNEW" "file://$T/no-feed-yet.xml" TestUpdater
  signer_signs_as "$KNEW"
  run --separate-stderr sign_and_appcast
  [ "$status" -eq 0 ]
  [[ "$output" == *"sparkle:edSignature=\"signed-by:$KNEW\""* ]]
}

@test "a signature installed clients would reject gets no appcast at all" {
  mkpkg "$T/new.pkg" "$KNEW" "file://$T/no-feed-yet.xml" TestUpdater
  signer_signs_as "$KOTHER"
  run --separate-stderr sign_and_appcast
  [ "$status" -ne 0 ]
  [[ "$output" != *"<rss"* ]]
  [[ "$stderr" == *"$KNEW"* ]]
}

@test "with no ed25519-verify beside --signer, and no --verifier, it refuses rather than skip the check" {
  mkpkg "$T/new.pkg" "$KNEW" "file://$T/no-feed-yet.xml" TestUpdater
  signer_signs_as "$KNEW"
  rm "$T/bin/ed25519-verify"
  run --separate-stderr sign_and_appcast
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"ed25519-verify"* ]]
  mkverifier "$T/elsewhere-verify"
  run --separate-stderr sign_and_appcast --verifier "$T/elsewhere-verify"
  [ "$status" -eq 0 ]
}

@test "--pubkey and --allow-key-change reach the check" {
  mkpkg "$T/new.pkg"                       # no updater: only --pubkey can say what clients trust
  signer_signs_as "$KNEW"
  run --separate-stderr sign_and_appcast
  [ "$status" -ne 0 ]
  run --separate-stderr sign_and_appcast --pubkey "$KNEW"
  [ "$status" -eq 0 ]
  mkpkg "$T/prev.pkg" "$KOTHER" "file://$T/appcast.xml" TestUpdater
  mkfeed "$T/appcast.xml" "file://$T/prev.pkg"
  mkpkg "$T/new.pkg" "$KNEW" "file://$T/appcast.xml" TestUpdater
  run --separate-stderr sign_and_appcast
  [ "$status" -ne 0 ]
  run --separate-stderr sign_and_appcast --allow-key-change
  [ "$status" -eq 0 ]
}
