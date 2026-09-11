#!/bin/sh
# The pkg must install on BOTH kinds of box and pick its own updater. Developing under Mavericks and
# developing under modern macOS are both first-class: an x86_64-only updater would prompt for Rosetta
# on Apple Silicon, and shipping two pkgs would make someone choose -- silently wrong when they
# choose badly. So one pkg carries both slices and the postinstall decides.
#
# BEHAVIORAL, not grep: an earlier cut of this test grepped the postinstall for `uname -m` and
# `arm64` and passed a postinstall that loaded the x86_64 agent on every box. So this RUNS the
# postinstall the way Installer does ($1 pkg, $2 install location, $3 target volume) against a fixture
# volume holding both slices, with sysctl/uname/stat/sudo stubbed, and checks what it actually did.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
S="$root/scripts/package-pkg.sh"
[ -f "$S" ] || { echo "FAIL: no scripts/package-pkg.sh"; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/pkgpost.XXXXXX")"; trap 'rm -rf "$work"' EXIT

NATIVE_LABEL=dev.modernmavericks.mavericks-shipyard-updatecheck
CROSS_LABEL=dev.modernmavericks.mavericks-shipyard-cross-updatecheck
NATIVE_APP=MavericksShipyardUpdater.app
CROSS_APP=MavericksShipyardCrossUpdater.app
APPDIR="Library/Application Support/ModernMavericks"
PAYLOAD=usr/local/mavericks-shipyard

# The postinstall is the part with logic worth testing; emit and exercise it without building a real
# pkg (pkgbuild needs a full payload and minutes; this needs neither).
scr="$work/scripts"; mkdir -p "$scr"
sh "$S" --emit-postinstall "$scr/postinstall" || { echo "FAIL: --emit-postinstall failed"; exit 1; }
[ -s "$scr/postinstall" ] || { echo "FAIL: empty postinstall"; exit 1; }

# Stand-ins for the two rendered agent-load fragments: each records that it was sourced.
for slice in native cross; do
  printf 'echo %s >> "%s"\n' "$slice" "$work/sourced.log" > "$scr/agent-load-$slice.sh"
done

# Stubs first on PATH. sudo only records its argv -- one [arg] per argument, so a word-split or a
# dropped quote shows up as a mismatch. sysctl and stat answer ONLY the exact question the postinstall
# must ask; anything else is logged and exits 97, so a regression to `stat -f %u` (a uid, not a name)
# or to another sysctl cannot pass on a stub that ignores its arguments.
#
# sysctl hw.optional.arm64 is the forced "hardware": 1 (Apple Silicon), 0 (Intel on a modern macOS),
# or absent (10.9 has no such name: nothing on stdout, an error, exit 1). uname -m always says x86_64,
# which is what it says under Rosetta -- where Installer runs a package's scripts on Apple Silicon
# unless the Distribution declares arm64 -- so a postinstall that trusts uname -m picks the wrong slice.
bin="$work/bin"; mkdir -p "$bin"
cat > "$bin/sysctl" <<'EOF'
#!/bin/sh
if [ "$#" -ne 2 ] || [ "$1" != -n ] || [ "$2" != hw.optional.arm64 ]; then
  echo "sysctl $*" >> "$FAKE_STUB_ERRORS"; exit 97
fi
case "$FAKE_ARM64" in
  absent) echo "second level name optional in hw.optional.arm64 is invalid" >&2; exit 1 ;;
  *) echo "$FAKE_ARM64" ;;
esac
EOF
cat > "$bin/uname" <<'EOF'
#!/bin/sh
echo x86_64
EOF
cat > "$bin/stat" <<'EOF'
#!/bin/sh
if [ "$#" -ne 3 ] || [ "$1" != -f ] || [ "$2" != %Su ] || [ "$3" != /dev/console ]; then
  echo "stat $*" >> "$FAKE_STUB_ERRORS"; exit 97
fi
echo "$FAKE_USER"
EOF
cat > "$bin/sudo" <<'EOF'
#!/bin/sh
for a in "$@"; do printf '[%s]' "$a"; done >> "$FAKE_SUDO_LOG"
echo >> "$FAKE_SUDO_LOG"
exit "${FAKE_SUDO_RC:-0}"
EOF
chmod +x "$bin/sysctl" "$bin/uname" "$bin/stat" "$bin/sudo"

# A target volume on which the pkg has just laid down its payload: BOTH slices, both agents.
lay_down_volume() {  # $1 = volume root
  rm -rf "$1"
  mkdir -p "$1/Library/LaunchAgents" "$1/$PAYLOAD/scripts" \
           "$1/$APPDIR/$NATIVE_APP/Contents/MacOS" "$1/$APPDIR/$CROSS_APP/Contents/MacOS"
  : > "$1/Library/LaunchAgents/$NATIVE_LABEL.plist"
  : > "$1/Library/LaunchAgents/$CROSS_LABEL.plist"
  : > "$1/$PAYLOAD/scripts/register-with-cmake.sh"
}

# Run the postinstall as Installer would. Sets $rc, $out, $sourced, $sudo_argv, $stub_errors.
run_postinstall() {  # $1 = hw.optional.arm64 (1|0|absent)  $2 = console user  $3 = target volume as passed in $3
  : > "$work/sourced.log"; : > "$work/sudo.log"; : > "$work/stub-errors.log"
  rc=0
  out="$(PATH="$bin:$PATH" FAKE_ARM64="$1" FAKE_USER="$2" FAKE_SUDO_LOG="$work/sudo.log" \
         FAKE_STUB_ERRORS="$work/stub-errors.log" \
         sh "$scr/postinstall" /fake/mavericks-shipyard.pkg "$3" "$3" 2>&1)" || rc=$?
  sourced="$(cat "$work/sourced.log")"
  sudo_argv="$(cat "$work/sudo.log")"
  stub_errors="$(cat "$work/stub-errors.log")"
}

fail() { echo "FAIL: $*"; [ -z "${out:-}" ] || printf '%s\n' "$out" | sed 's/^/    | /'; exit 1; }

# Each slice: load the matching agent and ONLY it, remove the other (launchd autoloads anything in
# /Library/LaunchAgents at the next login, so merely not loading it now is not enough), and register
# as the console user through their login shell -- the postinstall is root with Installer's minimal
# PATH, so "whatever cmake is on PATH" can only mean the developer's PATH, and HOME must be theirs.
check_slice() {  # $1 = hw.optional.arm64  $2 = slice kept  $3 = label kept  $4 = app kept  $5 = label dropped  $6 = app dropped  $7 = volume arg
  vol="$work/vol"; lay_down_volume "$vol"
  run_postinstall "$1" alice "$7"
  [ "$rc" -eq 0 ] || fail "$1: postinstall exited $rc"
  [ -z "$stub_errors" ] || fail "$1: asked a stub the wrong question: $stub_errors"
  [ "$sourced" = "$2" ] || fail "$1: sourced '$sourced', want exactly '$2'"
  [ ! -e "$vol/Library/LaunchAgents/$5.plist" ] || fail "$1: the other slice's agent is still installed; launchd will load it at login"
  [ ! -e "$vol/$APPDIR/$6" ] || fail "$1: the other slice's app is still installed"
  [ -f "$vol/Library/LaunchAgents/$3.plist" ] || fail "$1: removed its own agent"
  [ -d "$vol/$APPDIR/$4" ] || fail "$1: removed its own app"
  want="[-u][alice][-i][sh][$vol/$PAYLOAD/scripts/register-with-cmake.sh][$vol/$PAYLOAD]"
  [ "$sudo_argv" = "$want" ] || fail "$1: sudo got '$sudo_argv', want '$want'"
}
# Apple Silicon keeps the arm64 slice even though uname -m (stubbed as under Rosetta) says x86_64.
check_slice 1      cross  "$CROSS_LABEL"  "$CROSS_APP"  "$NATIVE_LABEL" "$NATIVE_APP" "$work/vol"
# Intel on a modern macOS answers 0. It also passes the volume with a trailing slash ("/" is what
# Installer passes for the boot volume), which must not double up into "//usr/local/...".
check_slice 0      native "$NATIVE_LABEL" "$NATIVE_APP" "$CROSS_LABEL"  "$CROSS_APP"  "$work/vol/"
# 10.9 has no hw.optional.arm64 at all: an error and no output must mean native, not a failed install.
check_slice absent native "$NATIVE_LABEL" "$NATIVE_APP" "$CROSS_LABEL"  "$CROSS_APP"  "$work/vol"

# Nobody at the console (loginwindow, a remote install): there is no developer to register for, and
# registering as root would write a root-owned entry nobody's cmake reads. Skip, and SAY how to finish.
lay_down_volume "$work/vol"
run_postinstall absent root "$work/vol"
[ "$rc" -eq 0 ] || fail "console user root: postinstall exited $rc"
[ -z "$sudo_argv" ] || fail "console user root: sudo must not be called; got '$sudo_argv'"
printf '%s' "$out" | grep -q "sh \"$work/vol/$PAYLOAD/scripts/register-with-cmake.sh\" \"$work/vol/$PAYLOAD\"" \
  || fail "console user root: the output must name the recovery command"

# Registration is BEST-EFFORT: shipyard's scripts half works with no cmake at all, and swift-toolchain
# consumes only that half. A cmake-less box (register-with-cmake.sh refuses) must still install.
lay_down_volume "$work/vol"
FAKE_SUDO_RC=1; export FAKE_SUDO_RC
run_postinstall 1 alice "$work/vol"
unset FAKE_SUDO_RC
[ "$rc" -eq 0 ] || fail "a failed registration must not fail the install; postinstall exited $rc"

# The postinstall hardcodes the two .app names, so the packager must refuse any others -- a swapped
# pair would ship the x86_64 updater under the arm64 name and bring the Rosetta prompt straight back.
mkdir -p "$work/apps/$NATIVE_APP" "$work/apps/$CROSS_APP" "$work/payload/scripts"
if out="$(sh "$S" --payload "$work/payload" --app-native "$work/apps/$CROSS_APP" \
            --app-cross "$work/apps/$NATIVE_APP" --version 0.0.0 --out "$work/x.pkg" 2>&1)"; then
  fail "swapped --app-native/--app-cross must be refused"
fi
printf '%s' "$out" | grep -q "$NATIVE_APP" || fail "the refusal must name the expected app"

# The Distribution must declare BOTH architectures, and exactly those. Without arm64 in it, Installer
# on Apple Silicon offers Rosetta for a pkg with scripts and runs them translated. Only one arch would
# stop the pkg installing on the other box. Non-comment lines only: the script explains the flag in prose.
out=""
host_arch="$(grep -v '^[[:space:]]*#' "$S" | grep -o -- '--host-arch[[:space:]]*[^[:space:]]*' || true)"
[ "$host_arch" = "--host-arch x86_64,arm64" ] \
  || fail "package-pkg.sh must pass exactly --host-arch x86_64,arm64 to set_install_floor.sh; got '${host_arch:-nothing}'"


echo "PASS: shipyard-package-pkg"
