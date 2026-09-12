#!/bin/sh
# Package shipyard (spec 2026-09-11): one prefix holding shipyard's own CMake and shipyard itself,
# three uniquely named commands on the default PATH, and one universal updater.
#
#   /usr/local/mavericks-shipyard/{bin/{cmake,ctest,cpack}, share/cmake-X.Y, share/cmake/MavericksShipyard}
#   /usr/local/bin/shipyard-{cmake,ctest,cpack} -> ../mavericks-shipyard/bin/{cmake,ctest,cpack}
#
# A cmake always searches its own install prefix, and finds that prefix through a symlink -- so
# shipyard-cmake finds shipyard with no registry, no PATH change and no CMAKE_PREFIX_PATH, and
# MavericksShipyardConfig.cmake refuses every other cmake. /usr/local/bin is on macOS's default PATH
# (/etc/paths); the three names are ours alone, so nothing shared is written into.
#
# --host-arch x86_64,arm64 declares BOTH arches: without arm64 in hostArchitectures, Installer on
# Apple Silicon offers Rosetta for a pkg with scripts. Declaring both restricts nothing.
#
# A preinstall clears the product dir first: Installer never deletes files a newer payload dropped,
# and with a bundled CMake every version bump would otherwise leave the old share/cmake-X.Y behind.
#
# The updater is a stopgap until Mavericks Lineup; only this script and the release workflow know it.
#   usage: package-pkg.sh --cmake-tree DIR --shipyard-prefix DIR --app APP --version V --out PKG
#          package-pkg.sh --emit-preinstall FILE     (for tests)
set -eu
SELF="$(cd "$(dirname "$0")" && pwd)"
TREE=""; SPREFIX=""; APP=""; VER=""; OUT=""; EMIT_PRE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --cmake-tree) TREE="${2%/}"; shift 2;;
    --shipyard-prefix) SPREFIX="${2%/}"; shift 2;;
    --app) APP="${2%/}"; shift 2;;
    --version) VER="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --emit-preinstall) EMIT_PRE="$2"; shift 2;;
    *) echo "package-pkg: unknown option $1" >&2; exit 2;;
  esac
done

ID="dev.modernmavericks.mavericks-shipyard"
PREFIX_DIR="/usr/local/mavericks-shipyard"
APPDIR="/Library/Application Support/ModernMavericks"
APP_NAME="MavericksShipyardUpdater.app"
LABEL="dev.modernmavericks.mavericks-shipyard-updatecheck"

# The preinstall spells the path out literally: a destructive path must not be one empty variable
# away from "$ROOT" alone. The test's fixture uses the same path.
emit_preinstall() {  # $1 = destination file
  cat > "$1" <<'PRE'
#!/bin/sh
# Rendered by package-pkg.sh -- do not edit here.
#
# Clear the product dir before Installer lays down the new one. Installer only adds and overwrites; it
# never deletes a file a newer payload no longer carries -- a removed script would keep working here
# while CI fails, and every CMake bump would leave the old share/cmake-X.Y behind. The dir is
# product-owned, so nothing but shipyard lives there. The path is a FIXED constant under the target
# volume, never built from a variable that could be empty; with no target volume ($3 unset, which
# Installer never does) this removes nothing rather than assume "/".
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

if [ -n "$EMIT_PRE" ]; then emit_preinstall "$EMIT_PRE"; exit 0; fi

: "${TREE:?package-pkg: --cmake-tree required}"
: "${SPREFIX:?package-pkg: --shipyard-prefix required}"
: "${APP:?package-pkg: --app required}"
: "${VER:?package-pkg: --version required}"
: "${OUT:?package-pkg: --out required}"

[ "$(basename "$APP")" = "$APP_NAME" ] \
  || { echo "package-pkg: --app must be a $APP_NAME (its LaunchAgent runs that name); got $APP" >&2; exit 2; }
[ -d "$APP" ] || { echo "package-pkg: no such app: $APP" >&2; exit 1; }
for f in bin/cmake bin/ctest bin/cpack; do
  [ -x "$TREE/$f" ] || { echo "package-pkg: --cmake-tree has no $f: $TREE" >&2; exit 1; }
done
require_only() {  # $1 = flag  $2 = dir  $3 = allowed top-level names, space-separated
  _flag="$1"; _dir="$2"; _allowed="$3"
  for _e in "$_dir"/* "$_dir"/.*; do
    [ -e "$_e" ] || continue                        # an unmatched glob stays literal
    _b="$(basename "$_e")"
    case "$_b" in
      .|..) continue ;;
      ._*) continue ;;                              # stripped from the stage below, so it never ships
    esac
    _ok=no
    for _a in $_allowed; do
      if [ "$_b" = "$_a" ]; then _ok=yes; fi
    done
    [ "$_ok" = yes ] || {
      echo "package-pkg: $_flag has an unexpected top-level entry: $_b" >&2
      echo "    everything at the root of $_dir is installed into $PREFIX_DIR, and the payload is" >&2
      echo "    specified exactly (spec 2026-09-11 decision 1): $_allowed" >&2
      echo "    move $_dir/$_b elsewhere, or add it to the payload deliberately" >&2
      exit 1
    }
  done
}
# Both roots BECOME the product prefix verbatim, so decision 1's enumeration of the payload is a gate
# rather than a description: a stray shipyard-cmake-tree.tar.gz left beside the tree it was made from
# shipped a copy of the whole payload inside the payload, and nothing complained. `man` is allowed
# though our bootstrap does not build it: CMake installs man pages there when Sphinx is present, and a
# doc-enabled build must not become a packaging failure.
require_only --cmake-tree "$TREE" "bin doc man share"
[ -f "$SPREFIX/share/cmake/MavericksShipyard/MavericksShipyardConfig.cmake" ] \
  || { echo "package-pkg: --shipyard-prefix has no share/cmake/MavericksShipyard: $SPREFIX" >&2; exit 1; }
# Shipyard's own shape is just as fixed: every install() in CMakeLists.txt targets
# ${CMAKE_INSTALL_DATADIR}/cmake/MavericksShipyard, so `share` is the only thing that may be there.
# Anything else means a build dir, a source tree or a shared prefix was passed by mistake.
require_only --shipyard-prefix "$SPREFIX" "share"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/shipyard-pkg.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/stage"; SCR="$WORK/scripts"
mkdir -p "$STAGE$PREFIX_DIR" "$STAGE/usr/local/bin" "$SCR" "$WORK/component" "$(dirname "$OUT")"
# One prefix: the CMake tree, then shipyard installed into it (share/cmake/MavericksShipyard).
COPYFILE_DISABLE=1 cp -R "$TREE"/. "$STAGE$PREFIX_DIR/"
COPYFILE_DISABLE=1 cp -R "$SPREFIX"/. "$STAGE$PREFIX_DIR/"
# Spelled out rather than looped over "$c": these three names are the product's entire public
# surface on the default PATH, so they must be greppable here and in review, not assembled. The
# targets are RELATIVE, so the links resolve on whatever volume Installer lays them down on.
ln -s ../mavericks-shipyard/bin/cmake "$STAGE/usr/local/bin/shipyard-cmake"
ln -s ../mavericks-shipyard/bin/ctest "$STAGE/usr/local/bin/shipyard-ctest"
ln -s ../mavericks-shipyard/bin/cpack "$STAGE/usr/local/bin/shipyard-cpack"

# The updater and its LaunchAgent; stage_updater.sh renders the postinstall that loads the agent.
sh "$SELF/stage_updater.sh" --stage "$STAGE" --app "$APP" --app-dir "$APPDIR" \
  --agent-label "$LABEL" --scripts-out "$SCR"
emit_preinstall "$SCR/preinstall"

# AppleDouble sidecars an NFS/shared stage sprays would otherwise ship as payload.
find "$STAGE" -name '._*' -delete 2>/dev/null || true

# build_component_pkg.sh, not raw pkgbuild: the payload holds a .app, which pkgbuild would make
# relocatable and version-checked -- a locally built updater elsewhere on disk would capture it.
comp="$WORK/component/mavericks-shipyard.pkg"
sh "$SELF/build_component_pkg.sh" --root "$STAGE" --identifier "$ID" --version "$VER" \
  --install-location / --scripts "$SCR" --out "$comp" >&2

sh "$SELF/set_install_floor.sh" \
  --identifier "$ID" \
  --title "Mavericks Shipyard ${VER}" \
  --component "$comp" \
  --out "$OUT" \
  --host-arch x86_64,arm64 \
  --require-scripts >&2

echo "built $OUT" >&2
