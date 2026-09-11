bats_require_minimum_version 1.5.0

# The signing key must never be recoverable from a CI log. A public repo's Actions logs are public,
# and GitHub masks only the literal secret -- a trace, a slice or a re-encoding goes out as-is. So
# sign_and_appcast.sh must never let the shell expand SPARKLE_PRIVATE_KEY into a command: not for
# the signer (argv is also visible to every process that can list processes) and not even for a
# test of whether it is set, since `sh -x` prints every expanded command line.
#
# A stub signer stands in for ed25519-sign (the crypto is mavericks-ed25519's to test); it records
# what it was handed. The key is throwaway random bytes.
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  T="$BATS_TEST_TMPDIR"
  KEY="$(head -c 96 /dev/urandom | base64 | tr -d '\n')"
  cat > "$T/sign" <<EOF
#!/bin/sh
printf '%s\n' "\$*" > "$T/signer-argv"
cat > "$T/signer-stdin"
echo c3R1YnNpZ25hdHVyZWZvcnRlc3Rpbmdvbmx5QUFBQUFBQUFBQUFBQUFBQUFBQUFBQT09
EOF
  chmod +x "$T/sign"
  printf 'dummy pkg bytes\n' > "$T/x.pkg"
  printf '## Notes\n\n- thing\n' > "$T/notes.md"
}

sign_and_appcast() {  # [sh flags...] -- the rest of the args are sign_and_appcast.sh's
  sh "$@" "$ROOT/scripts/sign_and_appcast.sh" --signer "$T/sign" --channel-title "Test Channel" \
    --version 1.2.3 --pkg-url "https://example.invalid/x.pkg" --notes-file "$T/notes.md" \
    --pkg "$T/x.pkg" < /dev/null
}

# Fail if TEXT carries any 16-character window of KEY (12 bytes of it: already a brute force away
# from the rest, and no honest output contains 12 given random bytes by chance).
refute_key_in() {  # TEXT
  local i
  for ((i = 0; i + 16 <= ${#KEY}; i++)); do
    [[ "$1" != *"${KEY:i:16}"* ]] || { echo "key material at offset $i" >&2; return 1; }
  done
}

@test "the signer gets the key on stdin, and never on its command line" {
  SPARKLE_PRIVATE_KEY="$KEY" run sign_and_appcast
  [ "$status" -eq 0 ]
  [ "$(cat "$T/signer-stdin")" = "$KEY" ]
  refute_key_in "$(cat "$T/signer-argv")"
  [[ "$(cat "$T/signer-argv")" == "-f - "* ]]
}

@test "under sh -x, nothing sign_and_appcast.sh prints or traces carries a piece of the key" {
  SPARKLE_PRIVATE_KEY="$KEY" run sign_and_appcast -x
  [ "$status" -eq 0 ]
  [[ "$output" == *"sparkle:edSignature"* ]]   # it really ran, traced, to the end
  refute_key_in "$output"
}

@test "an unset key is refused, before anything is signed" {
  run env -u SPARKLE_PRIVATE_KEY sh "$ROOT/scripts/sign_and_appcast.sh" --signer "$T/sign" \
    --channel-title C --version 1.2.3 --pkg-url https://example.invalid/x.pkg \
    --notes-file "$T/notes.md" --pkg "$T/x.pkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SPARKLE_PRIVATE_KEY"* ]]
  [ ! -e "$T/signer-argv" ]
}

@test "an empty key is refused, before anything is signed" {
  SPARKLE_PRIVATE_KEY= run sign_and_appcast
  [ "$status" -ne 0 ]
  [[ "$output" == *"SPARKLE_PRIVATE_KEY"* ]]
  [ ! -e "$T/signer-argv" ]
}
