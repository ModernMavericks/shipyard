#!/bin/sh
# Package shipyard: the payload, BOTH updater slices, and a postinstall that picks one.
#
# Both slices in one pkg because developing under Mavericks and developing under modern macOS are
# equally first-class. An x86_64-only updater is cheaper and matches every other family product, but
# it prompts for Rosetta on Apple Silicon; two pkgs would make someone choose, and choosing wrong is
# silent. So: one artifact, no prompt, no choice.
#
# --host-arch x86_64,arm64 -- BOTH, which is the opposite of the restriction the family's "no
# --host-arch" rule forbids (that rule stops a pkg being limited to ONE arch, which would refuse the
# other box). Without arm64 in hostArchitectures, Installer on Apple Silicon offers Rosetta for a pkg
# that has scripts and runs those scripts translated -- the very prompt this pkg exists to avoid.
#
# The postinstall is shipyard's own (not stage_updater.sh --scripts-out), because it must also pick an
# arch and register with cmake. It sources an agent-load fragment rendered by --snippet-out, exactly as
# mavericks-magic-trackpad2 does for its kext -- one fragment PER SLICE, since each has its label
# baked in. A preinstall clears the payload dir first, so files dropped from a newer payload go away.
#
# The updater is a stopgap until Mavericks Lineup exists, so beyond its own build option only this
# script and the release workflow that calls it know about it. Registration logic stays in
# register-with-cmake.sh, which the postinstall merely calls.
#   usage: package-pkg.sh --payload DIR --app-native APP --app-cross APP --version V --out PKG
#          package-pkg.sh --emit-postinstall FILE    (for tests)
#          package-pkg.sh --emit-preinstall FILE     (for tests)
set -eu
SELF="$(cd "$(dirname "$0")" && pwd)"
PAYLOAD=""; APP_NATIVE=""; APP_CROSS=""; VER=""; OUT=""; EMIT=""; EMIT_PRE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --payload) PAYLOAD="$2"; shift 2;;
    --app-native) APP_NATIVE="$2"; shift 2;;
    --app-cross) APP_CROSS="$2"; shift 2;;
    --version) VER="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --emit-postinstall) EMIT="$2"; shift 2;;
    --emit-preinstall) EMIT_PRE="$2"; shift 2;;
    *) echo "package-pkg: unknown option $1" >&2; exit 2;;
  esac
done

ID="dev.modernmavericks.mavericks-shipyard"
PAYLOAD_DIR="/usr/local/mavericks-shipyard"
APPDIR="/Library/Application Support/ModernMavericks"
# native = x86_64, min 10.9; cross = arm64. Names match Task 2's updater targets.
NATIVE_APP="MavericksShipyardUpdater.app"
CROSS_APP="MavericksShipyardCrossUpdater.app"
NATIVE_LABEL="dev.modernmavericks.mavericks-shipyard-updatecheck"
CROSS_LABEL="dev.modernmavericks.mavericks-shipyard-cross-updatecheck"

emit_postinstall() {  # $1 = destination file
  {
    cat <<'HEAD'
#!/bin/sh
# Rendered by package-pkg.sh -- do not edit here.
#
# Load the updater matching THIS machine, remove the other, then point cmake at the payload.
#
# Both slices ship in this pkg so neither kind of developer is second-class: no Rosetta prompt on
# Apple Silicon, and nothing to choose wrong. Only the matching agent may run.
#
# Never fails the install: every step is best-effort, and the payload is already on disk by now.
HEAD
    printf "PAYLOAD_DIR='%s'\nAPPDIR='%s'\n" "$PAYLOAD_DIR" "$APPDIR"
    printf "NATIVE_APP='%s'\nNATIVE_LABEL='%s'\n" "$NATIVE_APP" "$NATIVE_LABEL"
    printf "CROSS_APP='%s'\nCROSS_LABEL='%s'\n" "$CROSS_APP" "$CROSS_LABEL"
    cat <<'POST'
set -u
# $3 is the target volume: "/" for the boot volume, giving ROOT="". Every installed path goes through
# ROOT, so an install to another volume touches that volume (and a test can use a fixture root).
ROOT="${3:-/}"; ROOT="${ROOT%/}"
PAYLOAD="$ROOT$PAYLOAD_DIR"

# Ask the HARDWARE, not `uname -m`. Under Rosetta uname -m says x86_64 on Apple Silicon, and Installer
# runs a pkg's scripts under Rosetta whenever the Distribution does not declare arm64 -- so a uname
# test keeps the x86_64 slice on exactly the box it must not. hw.optional.arm64 is 1 on Apple Silicon
# even when translated. Intel answers 0; 10.9 has no such name (an error, no output). Both are native.
case "$(sysctl -n hw.optional.arm64 2>/dev/null)" in
  1) keep=cross;  drop_label=$NATIVE_LABEL; drop_app=$NATIVE_APP ;;
  *) keep=native; drop_label=$CROSS_LABEL;  drop_app=$CROSS_APP ;;  # Intel, 10.9, or no answer
esac

# REMOVE the other slice, not merely skip loading it: launchd autoloads everything in
# /Library/LaunchAgents at the next login, which would run the wrong updater (on arm64, a Rosetta
# prompt) whatever this script does now.
rm -f "$ROOT/Library/LaunchAgents/$drop_label.plist" \
  || echo "mavericks-shipyard: could not remove $ROOT/Library/LaunchAgents/$drop_label.plist" >&2
rm -rf "$ROOT$APPDIR/$drop_app" \
  || echo "mavericks-shipyard: could not remove $ROOT$APPDIR/$drop_app" >&2

# The agent-load fragments are rendered by shipyard's own stage_updater.sh, so every product loads its
# agent the same way. Sourced, not run: they define MAV_* and contain no exit.
AGENT_LOAD="$(dirname "$0")/agent-load-$keep.sh"
[ -f "$AGENT_LOAD" ] && . "$AGENT_LOAD"

# Registration is BEST-EFFORT: shipyard's shell scripts work with no cmake at all, and swift-toolchain
# consumes only that half. A cmake-less box still gets a working install; the script says what is
# missing and how to finish later.
#
# It runs AS THE CONSOLE USER, through their login shell (-i). This postinstall is root with
# Installer's minimal PATH, where no pkgsrc/Homebrew/CMake.app cmake lives, and root's HOME: run
# directly it would register nothing, or write a root-owned entry nobody's cmake reads. "Whatever
# cmake is on PATH" can only mean the developer's PATH. The logic stays in register-with-cmake.sh, not
# here, so recovery by hand runs the same code.
register="$PAYLOAD/scripts/register-with-cmake.sh"
user=$(stat -f %Su /dev/console 2>/dev/null || true)
case "$user" in
  ''|root|_*)  # nobody at the console (loginwindow is root; _* are system accounts)
    echo "mavericks-shipyard: no one is logged in, so cmake registration was skipped."
    echo "    to finish, as yourself: sh \"$register\" \"$PAYLOAD\""
    ;;
  *)
    # </dev/null: a login profile that prompts must not hang the install waiting for input.
    sudo -u "$user" -i sh "$register" "$PAYLOAD" </dev/null || true
    ;;
esac
exit 0
POST
  } > "$1"
  chmod +x "$1"
}

# The preinstall spells out PAYLOAD_DIR literally instead of interpolating it: a destructive path must
# not be one empty variable away from "$ROOT" alone. The test's fixture uses the same path, so the two
# cannot drift apart unnoticed.
emit_preinstall() {  # $1 = destination file
  cat > "$1" <<'PRE'
#!/bin/sh
# Rendered by package-pkg.sh -- do not edit here.
#
# Clear the payload dir before Installer lays down the new one. Installer only adds and overwrites; it
# never deletes a file that a newer payload no longer carries. So a script removed or renamed in
# shipyard would keep working on every dev box that ever installed it, while CI (which installs from
# source) fails -- the drift this pkg exists to end. The dir is product-owned (spec decision 2: a
# self-contained tree, not a shared namespace), so nothing but shipyard lives there; the cost is that
# anything hand-placed inside it is lost on update.
#
# The path is a FIXED constant under the target volume, never built from a variable that could be
# empty, so this cannot remove anything but that one dir. With no target volume at all ($3 unset,
# which Installer never does) it removes nothing rather than assume "/".
#
# Never fails the install: whatever this cannot remove, the payload still overwrites.
[ -n "${3:-}" ] || { echo "mavericks-shipyard: preinstall got no target volume; removing nothing" >&2; exit 0; }
ROOT="${3%/}"
rm -rf "$ROOT/usr/local/mavericks-shipyard" \
  || echo "mavericks-shipyard: could not clear $ROOT/usr/local/mavericks-shipyard; files dropped from this version may linger" >&2
exit 0
PRE
  chmod +x "$1"
}

if [ -n "$EMIT" ] || [ -n "$EMIT_PRE" ]; then
  [ -z "$EMIT" ] || emit_postinstall "$EMIT"
  [ -z "$EMIT_PRE" ] || emit_preinstall "$EMIT_PRE"
  exit 0
fi

: "${PAYLOAD:?package-pkg: --payload required}"
: "${APP_NATIVE:?package-pkg: --app-native required}"
: "${APP_CROSS:?package-pkg: --app-cross required}"
: "${VER:?package-pkg: --version required}"
: "${OUT:?package-pkg: --out required}"

# A trailing slash would make cp -R copy the bundle's CONTENTS instead of the bundle.
APP_NATIVE="${APP_NATIVE%/}"; APP_CROSS="${APP_CROSS%/}"

# The postinstall knows each slice by .app name. Anything else -- including the two swapped -- would
# ship an updater the postinstall cannot find, or the x86_64 one under the arm64 name.
check_app() {  # $1 = flag  $2 = path given  $3 = required basename
  [ "$(basename "$2")" = "$3" ] \
    || { echo "package-pkg: $1 must be a $3 (the postinstall looks for that name); got $2" >&2; exit 2; }
  [ -d "$2" ] || { echo "package-pkg: $1: no such app: $2" >&2; exit 1; }
}
check_app --app-native "$APP_NATIVE" "$NATIVE_APP"
check_app --app-cross "$APP_CROSS" "$CROSS_APP"
for f in MavericksShipyardConfig.cmake scripts/register-with-cmake.sh; do
  [ -f "$PAYLOAD/$f" ] || { echo "package-pkg: --payload has no $f: $PAYLOAD" >&2; exit 1; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/shipyard-pkg.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/stage"; SCR="$WORK/scripts"
mkdir -p "$STAGE$PAYLOAD_DIR" "$SCR" "$WORK/component" "$(dirname "$OUT")"
COPYFILE_DISABLE=1 cp -R "$PAYLOAD"/. "$STAGE$PAYLOAD_DIR/"

# Stage each slice with its own agent label, and render each slice's agent-load fragment with that
# label baked in; the postinstall sources the one matching the machine.
sh "$SELF/stage_updater.sh" --stage "$STAGE" --app "$APP_NATIVE" --app-dir "$APPDIR" \
  --agent-label "$NATIVE_LABEL" --snippet-out "$SCR/agent-load-native.sh"
sh "$SELF/stage_updater.sh" --stage "$STAGE" --app "$APP_CROSS" --app-dir "$APPDIR" \
  --agent-label "$CROSS_LABEL" --snippet-out "$SCR/agent-load-cross.sh"

emit_preinstall "$SCR/preinstall"
emit_postinstall "$SCR/postinstall"

# AppleDouble sidecars an NFS/shared stage sprays would otherwise ship as payload.
find "$STAGE" -name '._*' -delete 2>/dev/null || true

# build_component_pkg.sh, not raw pkgbuild: the payload holds .app bundles, which pkgbuild makes
# relocatable and version-checked by default -- so a developer with a locally built updater elsewhere
# on disk (same bundle id) would get this payload installed INTO that build dir.
comp="$WORK/component/mavericks-shipyard.pkg"
sh "$SELF/build_component_pkg.sh" --root "$STAGE" --identifier "$ID" --version "$VER" \
  --install-location / --scripts "$SCR" --out "$comp" >&2

# Both arches, so this installs on Intel and Apple Silicon alike AND its scripts run natively on
# Apple Silicon (see the header). Declaring both restricts nothing.
sh "$SELF/set_install_floor.sh" \
  --identifier "$ID" \
  --title "Mavericks Shipyard ${VER}" \
  --component "$comp" \
  --out "$OUT" \
  --host-arch x86_64,arm64 \
  --require-scripts >&2

echo "built $OUT" >&2
