# msc.sh -- sourced by a ModernMavericks product's build scripts: locate shipyard's scripts as $SHIPYARD
# (and export SHIPYARD_SCRIPTS). CANONICAL COPY: shipyard's scripts/templates/msc.sh. The conventions
# gate requires every product's copy to match it byte for byte -- change it there, not here.
#
# CI: install@v1 exported SHIPYARD_SCRIPTS. Anywhere else: ask shipyard-cmake -- the only cmake that
# configures against shipyard -- where find_package(MavericksShipyard) lands, so a CMAKE_PREFIX_PATH
# dev override moves the scripts together with the modules. About 2 s; exported so children skip it.
SHIPYARD="${SHIPYARD_SCRIPTS:-}"
if [ ! -d "$SHIPYARD" ]; then
  _msc_probe="$(mktemp -d "${TMPDIR:-/tmp}/shipyard-probe.XXXXXX")"
  printf '%s\n' 'cmake_minimum_required(VERSION 3.16)' 'project(shipyard_probe NONE)' \
    'find_package(MavericksShipyard REQUIRED)' 'message(STATUS "SHIPYARD_DIR=${MavericksShipyard_DIR}")' \
    > "$_msc_probe/CMakeLists.txt"
  SHIPYARD="$(shipyard-cmake -S "$_msc_probe" -B "$_msc_probe/b" 2>/dev/null | sed -n 's/^-- SHIPYARD_DIR=//p')/scripts"
  rm -rf "$_msc_probe"; unset _msc_probe
fi
[ -d "$SHIPYARD" ] || { echo "msc.sh: cannot locate shipyard -- install the shipyard pkg (it provides shipyard-cmake), or set SHIPYARD_SCRIPTS" >&2; return 1 2>/dev/null || exit 1; }
SHIPYARD_SCRIPTS="$SHIPYARD"
export SHIPYARD SHIPYARD_SCRIPTS
