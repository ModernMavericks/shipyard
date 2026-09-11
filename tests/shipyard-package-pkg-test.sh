#!/bin/sh
# The pkg (spec 2026-09-11 decision 1): a prefix holding shipyard's own CMake and shipyard itself, three
# uniquely named commands in /usr/local/bin, one universal updater. No registration, no arch picking.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"; root="$(cd "$here/.." && pwd)"
S="$root/scripts/package-pkg.sh"
[ -f "$S" ] || { echo "FAIL: no scripts/package-pkg.sh"; exit 1; }
w="$(mktemp -d "${TMPDIR:-/tmp}/pkg-test.XXXXXX")"; trap 'rm -rf "$w"' EXIT
code() { grep -v '^[[:space:]]*#' "$S"; }   # the script minus its comments

# Declared arches: both, exactly once, on a real line.
[ "$(code | grep -c -- '--host-arch x86_64,arm64')" = 1 ] || { echo "FAIL: package-pkg.sh must pass --host-arch x86_64,arm64 exactly once"; exit 1; }
# The superseded machinery is gone.
for gone in register-with-cmake sysctl CrossUpdater agent-load-cross uname; do
  code | grep -q -- "$gone" && { echo "FAIL: package-pkg.sh still mentions $gone"; exit 1; }
done
# The three commands, as relative symlinks into the prefix.
for c in cmake ctest cpack; do
  code | grep -q "shipyard-$c" || { echo "FAIL: package-pkg.sh never creates /usr/local/bin/shipyard-$c"; exit 1; }
done

# The preinstall: removes exactly the product dir under the target volume; exits 0 always.
sh "$S" --emit-preinstall "$w/preinstall"
vol="$w/vol"; mkdir -p "$vol/usr/local/mavericks-shipyard/bin" "$vol/usr/local/other" "$vol/usr/local/bin"
touch "$vol/usr/local/mavericks-shipyard/bin/cmake" "$vol/usr/local/other/keep" "$vol/usr/local/bin/keep"
sh "$w/preinstall" /fake.pkg / "$vol/" || { echo "FAIL: preinstall must exit 0"; exit 1; }
[ ! -e "$vol/usr/local/mavericks-shipyard" ] || { echo "FAIL: preinstall must remove the product dir"; exit 1; }
[ -f "$vol/usr/local/other/keep" ] && [ -f "$vol/usr/local/bin/keep" ] || { echo "FAIL: preinstall removed a neighbour"; exit 1; }
# No target volume: remove nothing. rm is STUBBED for this case -- with $3 unset a broken guard would
# reach for an unanchored /usr/local/mavericks-shipyard, i.e. this machine's own install. The stub
# records the call instead, so the test can fail loudly without ever removing anything real.
mkdir -p "$w/stub"
cat > "$w/stub/rm" <<'STUB'
#!/bin/sh
for a in "$@"; do printf '[%s]' "$a"; done >> "$FAKE_RM_LOG"
printf '\n' >> "$FAKE_RM_LOG"
STUB
chmod +x "$w/stub/rm"; : > "$w/rm.log"
mkdir -p "$vol/usr/local/mavericks-shipyard"
( PATH="$w/stub:$PATH"; FAKE_RM_LOG="$w/rm.log"; export FAKE_RM_LOG; sh "$w/preinstall" ) >/dev/null 2>&1 \
  || { echo "FAIL: preinstall with no \$3 must exit 0"; exit 1; }
[ ! -s "$w/rm.log" ] || { echo "FAIL: with no target volume the preinstall must remove nothing; it tried $(cat "$w/rm.log")"; exit 1; }
[ -d "$vol/usr/local/mavericks-shipyard" ] || { echo "FAIL: with no target volume the preinstall must remove nothing"; exit 1; }

# Usage: every required option is required, AND the refusal names the one that is missing -- a script
# that silently ignored a flag would still fail here (the paths are bogus) on some other complaint.
for missing in --cmake-tree --shipyard-prefix --app --version --out; do
  args="--cmake-tree $w/t --shipyard-prefix $w/p --app $w/MavericksShipyardUpdater.app --version 1.0.0 --out $w/o.pkg"
  args="$(printf '%s' "$args" | sed "s|$missing [^ ]*||")"
  # shellcheck disable=SC2086
  if err="$(sh "$S" $args 2>&1 >/dev/null)"; then echo "FAIL: $missing must be required"; exit 1; fi
  printf '%s\n' "$err" | grep -q -- "$missing" \
    || { echo "FAIL: the refusal for a missing $missing must name it; got '$err'"; exit 1; }
done
mkdir -p "$w/Other.app"
if sh "$S" --cmake-tree "$w/t" --shipyard-prefix "$w/p" --app "$w/Other.app" --version 1.0.0 --out "$w/o.pkg" >/dev/null 2>&1; then
  echo "FAIL: an app not named MavericksShipyardUpdater.app must be refused"; exit 1
fi

echo "PASS: shipyard-package-pkg"
