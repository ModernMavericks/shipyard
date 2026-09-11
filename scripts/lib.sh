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

# Absolute path to the INSTALLED mavericks-shipyard scripts dir: $MAVERICKS_SCRIPTS (tests), else
# $SHIPYARD_SCRIPTS -- which install@v1 exports in CI and a product's msc.sh exports locally (it asks
# shipyard-cmake). There is no registry to fall back on any more, and no hard-coded prefix.
msc_scripts() {
  if [ -n "${MAVERICKS_SCRIPTS:-}" ]; then printf '%s\n' "$MAVERICKS_SCRIPTS"; return 0; fi
  if [ -n "${SHIPYARD_SCRIPTS:-}" ] && [ -d "$SHIPYARD_SCRIPTS" ]; then printf '%s\n' "$SHIPYARD_SCRIPTS"; return 0; fi
  echo "msc_scripts: SHIPYARD_SCRIPTS is not set -- source the product's msc.sh first (it asks shipyard-cmake)," >&2
  echo "  or set MAVERICKS_SCRIPTS" >&2
  return 1
}

# Version ordering WITHOUT `sort -V`: the 10.9 box's BSD sort has no -V, so any script relying on it
# works in CI and dies on the platform this family targets. Promoted here from
# assert_appcast_upgradeable.sh, which had already hit that wall and grown a private copy rather than
# call previous-release-tag.sh; one comparator now serves both, so "which tag is highest" cannot drift
# between the gate that asserts the ordering and the script that picks the baseline.

# A version is in the comparator's orderable domain iff it is purely dotted-numeric.
numeric() {
  case "$1" in ''|.*|*.|*..*|*[!0-9.]*) return 1;; *) return 0;; esac
}

# echo 1/0/-1 for $1 vs $2 by component-wise numeric compare (missing component = 0); shorter-is-less.
ver_cmp() {
  awk -v a="$1" -v b="$2" 'BEGIN{
    na=split(a,A,"."); nb=split(b,B,"."); n=(na>nb)?na:nb;
    for(i=1;i<=n;i++){ x=(i<=na)?A[i]+0:0; y=(i<=nb)?B[i]+0:0;
      if(x>y){print 1; exit} if(x<y){print -1; exit} }
    print 0 }'
}
