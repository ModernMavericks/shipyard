bats_require_minimum_version 1.5.0

# scan_for_key.py FILE... fails when any file carries a piece of $SPARKLE_PRIVATE_KEY in any encoding
# a log or a release file could plausibly carry it in -- and says where, never what. It is the check
# every real signing run's logs go through (scan-for-key.yml). Keys here are throwaway random bytes.
setup() {
  command -v python3 >/dev/null || skip "python3 not installed (CI-only script)"
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  T="$BATS_TEST_TMPDIR"
  head -c 96 /dev/urandom > "$T/key.bin"          # private[64] || public[32], as ed25519-keygen writes
  KEY="$(base64 < "$T/key.bin" | tr -d '\n')"
  printf 'just a build log\nnothing to see: %s\n' "$(head -c 60 /dev/urandom | base64 | tr -d '\n')" > "$T/clean.log"
}

scan() { SPARKLE_PRIVATE_KEY="$KEY" python3 "$ROOT/scripts/scan_for_key.py" "$@"; }
# bytes START..START+LEN of the key blob, encoded as ENCODING
slice() {  # START LEN ENCODING
  python3 - "$T/key.bin" "$1" "$2" "$3" <<'EOF'
import base64, sys
b = open(sys.argv[1], 'rb').read()[int(sys.argv[2]):int(sys.argv[2]) + int(sys.argv[3])]
enc = sys.argv[4]
sys.stdout.write({'b64': base64.b64encode(b).decode(), 'url': base64.urlsafe_b64encode(b).decode(),
                  'hex': b.hex(), 'HEX': b.hex().upper()}[enc])
EOF
}
plant() {  # TEXT -- a log with TEXT on its third line
  printf 'line one\nline two\nleaked: %s\nline four\n' "$1" > "$T/leak.log"
}

@test "a clean log passes" {
  run --separate-stderr scan "$T/clean.log"
  [ "$status" -eq 0 ]
}

@test "the whole key is caught, and reported by file and line" {
  plant "$KEY"
  run --separate-stderr scan "$T/clean.log" "$T/leak.log"
  [ "$status" -eq 1 ]
  [[ "$output" == *"leak.log:3"* ]] || false
  [[ "$output" != *"clean.log"* ]] || false
}

@test "a 12-byte slice at each byte alignment, re-encoded as base64, is caught" {
  for start in 7 8 9; do
    plant "$(slice "$start" 12 b64)"
    run --separate-stderr scan "$T/leak.log"
    [ "$status" -eq 1 ]
  done
}

@test "url-safe base64 and hex in either case are caught" {
  for enc in url hex HEX; do
    plant "$(slice 20 12 "$enc")"
    run --separate-stderr scan "$T/leak.log"
    [ "$status" -eq 1 ]
  done
}

@test "raw key bytes inside a binary file are caught" {
  { head -c 1000 /dev/urandom; dd if="$T/key.bin" bs=1 skip=30 count=12 2>/dev/null; head -c 1000 /dev/urandom; } > "$T/asset.bin"
  run --separate-stderr scan "$T/asset.bin"
  [ "$status" -eq 1 ]
}

# The public half is printed on purpose (assert_update_trusted.sh names the keys it checks), and
# knowing it helps no one sign.
# A release artifact is a tree, not a flat list: openssh's carries dist/pkg-scripts/, and the first
# real scan refused to call "Is a directory" a pass -- correctly, but it had scanned nothing.
@test "a directory is scanned file by file, all the way down" {
  mkdir -p "$T/dist/pkg-scripts/deeper"
  echo 'clean notes' > "$T/dist/RELEASE_NOTES.md"
  printf 'x %s x\n' "$(slice 10 12 b64)" > "$T/dist/pkg-scripts/deeper/postinstall"
  run --separate-stderr scan "$T/dist"
  [ "$status" -eq 1 ]
  [[ "$output" == *"pkg-scripts/deeper/postinstall:1"* ]] || false
  rm "$T/dist/pkg-scripts/deeper/postinstall"
  run --separate-stderr scan "$T/dist"
  [ "$status" -eq 0 ]
}

@test "the public half alone is not a leak" {
  plant "$(slice 64 32 b64)"
  run --separate-stderr scan "$T/leak.log"
  [ "$status" -eq 0 ]
}

@test "a key that is not the 96-byte blob is secret in every byte" {
  KEY="$(head -c 32 /dev/urandom | tee "$T/key.bin" | base64 | tr -d '\n')"
  plant "$(slice 16 12 hex)"
  run --separate-stderr scan "$T/leak.log"
  [ "$status" -eq 1 ]
}

@test "what it reports carries no piece of the key" {
  plant "$KEY $(slice 5 40 hex) $(slice 3 30 url)"
  run scan "$T/leak.log"
  [ "$status" -eq 1 ]
  for ((i = 0; i + 16 <= ${#KEY}; i++)); do [[ "$output" != *"${KEY:i:16}"* ]] || false; done
  hex="$(slice 0 96 hex)"
  for ((i = 0; i + 24 <= ${#hex}; i++)); do [[ "$output" != *"${hex:i:24}"* ]] || false; done
}

@test "no key to look for is a usage error, not a pass" {
  run --separate-stderr env -i PATH="$PATH" python3 "$ROOT/scripts/scan_for_key.py" "$T/clean.log"
  [ "$status" -eq 2 ]
}

@test "a file it cannot read is an error, not a pass" {
  run --separate-stderr scan "$T/no-such.log"
  [ "$status" -eq 2 ]
}
