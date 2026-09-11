bats_require_minimum_version 1.5.0

# require_key_scan.sh DIST RECORD_DIR -- publish-release.yml's gate: a release that was signed (some
# file in it carries a sparkle:edSignature) must come with scan-for-key.yml's record that this run's
# logs and files were scanned for the key. PHASE 1 of the rollout: a missing record WARNS. Once every
# signing product calls scan-for-key.yml it becomes an error (SKILL.md backlog), and so does this test.
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/dist" "$T/record"
  echo notes > "$T/dist/RELEASE_NOTES.md"
}
gate() { sh "$ROOT/scripts/require_key_scan.sh" "$T/dist" "$T/record"; }
signed() { printf '<enclosure url="u" sparkle:edSignature="c2ln" length="1" />\n' > "$T/dist/appcast.xml"; }

@test "an unsigned release needs no scan and says nothing" {
  run gate
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a signed release with the scan's record passes, and shows it" {
  signed
  echo 'scanned 2 job logs and 3 release files' > "$T/record/sparkle-key-scan.txt"
  run gate
  [ "$status" -eq 0 ]
  [[ "$output" == *"scanned 2 job logs"* ]] || false
}

@test "phase 1: a signed release with no scan record warns, naming what to add" {
  signed
  run gate
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]] || false
  [[ "$output" == *"scan-for-key.yml"* ]] || false
}
