# scripts/lib.sh -- sourced helpers for the mavericks-* build scripts. No side effects on source.
#
# Promoted from three byte-identical per-repo copies (golang, macports-legacy-support, ed25519) that
# differed only in comment wording and the name of the root variable. $MAVERICKS_ROOT is that root;
# it defaults to the git toplevel so a plain `sh build/version.sh` still works from anywhere in a repo.
: "${MAVERICKS_ROOT:=$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# Bare upstream version (x.y.z, or a date for repos versioned by their pinned commit's date) from the
# committed UPSTREAM_VERSION file. $MAVERICKS_UPSTREAM_FILE overrides the path: a repo shipping
# parallel upstream lines keeps one per line (mavericks-golang: lines/126/UPSTREAM_VERSION), so which
# file to read is an input rather than a fixed location.
upstream_version() {
  tr -d '[:space:]' < "${MAVERICKS_UPSTREAM_FILE:-$MAVERICKS_ROOT/UPSTREAM_VERSION}"
}

# Absolute path to the INSTALLED mavericks-shipyard scripts dir. $SHIPYARD_SCRIPTS when install@v1
# exported it (CI), else the CMake user package registry -- what find_package consults -- never a
# hard-coded prefix and never a vendored copy. Override with MAVERICKS_SCRIPTS for tests.
msc_scripts() {
  if [ -n "${MAVERICKS_SCRIPTS:-}" ]; then printf '%s\n' "$MAVERICKS_SCRIPTS"; return 0; fi
  if [ -n "${SHIPYARD_SCRIPTS:-}" ] && [ -d "$SHIPYARD_SCRIPTS" ]; then printf '%s\n' "$SHIPYARD_SCRIPTS"; return 0; fi
  reg=$(ls "$HOME/.cmake/packages/MavericksShipyard/"* 2>/dev/null | head -1)
  if [ -n "$reg" ]; then
    d=$(cat "$reg")
    if [ -d "$d/scripts" ]; then printf '%s\n' "$d/scripts"; return 0; fi
  fi
  echo "msc_scripts: cannot locate installed mavericks-shipyard scripts" >&2
  echo "  install it (README 'Install (once)') or set MAVERICKS_SCRIPTS" >&2
  return 1
}
