bats_require_minimum_version 1.5.0
load lib/sparkle_pkg

# updater_pubkey.sh PKG -> the SUPublicEDKey and SUFeedURL of the Sparkle updater a .pkg installs:
# exactly what a fresh install of that pkg will trust, and where it will look for updates.
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  T="$BATS_TEST_TMPDIR"
  K1='11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo='
  K2='PUAXw+hDiVqStwqnTRt+vJyYLM8uxJaMwM1V8Sr0Zgw='
  FEED='https://github.com/ModernMavericks/test/releases/latest/download/appcast.xml'
}

pubkey() { sh "$ROOT/scripts/updater_pubkey.sh" "$@"; }

@test "reads the updater's key and feed out of a product archive" {
  mkpkg "$T/p.pkg" "$K1" "$FEED" TestUpdater
  run --separate-stderr pubkey "$T/p.pkg"
  [ "$status" -eq 0 ]
  [ "$output" = "SUPublicEDKey=$K1
SUFeedURL=$FEED" ]
}

@test "two updaters that agree (one per arch slice) give one answer" {
  mkpkg "$T/p.pkg" "$K1" "$FEED" TestUpdater "$K1" "$FEED" TestCrossUpdater
  run --separate-stderr pubkey "$T/p.pkg"
  [ "$status" -eq 0 ]
  [ "$output" = "SUPublicEDKey=$K1
SUFeedURL=$FEED" ]
}

@test "two updaters that disagree are refused: which one a client runs is not ours to guess" {
  mkpkg "$T/p.pkg" "$K1" "$FEED" TestUpdater "$K2" "$FEED" TestCrossUpdater
  run --separate-stderr pubkey "$T/p.pkg"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"disagree"* ]] || false
}

@test "a pkg that installs no updater says so" {
  mkpkg "$T/p.pkg"
  run --separate-stderr pubkey "$T/p.pkg"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"no Sparkle updater"* ]] || false
}

@test "a file that is not a pkg is refused" {
  echo 'not a pkg' > "$T/p.pkg"
  run --separate-stderr pubkey "$T/p.pkg"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}
