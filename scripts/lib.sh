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

# The state marker recorded in a release body or a notes file: "ModernMavericks-State: <value>"
# (spec 2026-09-12, decision 2). Reads a body on STDIN; prints the first marker's value, or nothing.
#
# ONE reader for the family, because two readers disagreeing is a live hazard rather than a style
# point. release-needed.sh once recognised only `ModernMavericks-State: v1:sha256:<hex>` while
# release-state-record.sh took anything after the key, so a body carrying an older-format marker was
# "no digest recorded" to the first and "a CONFLICTING digest" to the second -- and per ruling 1 the
# second exits 3 and fails the job. After the format bump the spec promises is safe ("recompute,
# never republish"), every migrated repo would have gone red nightly with no self-healing path.
#
# FIRST MARKER WINS, deliberately: a body with two markers is already broken, and taking the first
# makes both callers wrong about it in the same way instead of differently. (Both scripts had
# independently chosen `head -1`; that agreement is now structural rather than a coincidence.)
# Trailing whitespace is not part of the value -- a body is hand-editable, and a stray space must not
# turn a matching digest into a conflicting one.
state_marker() {
  sed -n 's/^ModernMavericks-State:[[:space:]]*//p' | sed 's/[[:space:]]*$//' | head -1
}

# Is VALUE a state digest THIS shipyard can read? A marker in another format is emphatically NOT
# "no marker": release-needed.sh must refuse to publish rather than treat it as absent, because
# treating a v1 marker as absent is exactly how a bump to v2 would republish all 14 products.
state_digest_readable() {
  case "${1:-}" in
    v1:sha256:*) case "${1#v1:sha256:}" in ''|*[!0-9a-f]*) return 1;; *) return 0;; esac ;;
    *) return 1 ;;
  esac
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

# The dotted-numeric key a Sparkle-style comparator can order, from a family version string:
#   1.102.0-mavericks.4 -> 1.102.0.4        the packaging axis becomes a final component
#   9.9p2-mavericks.3   -> 9.9.2.3          OpenSSH-portable's pN is MONOTONIC (p2 is newer than p1),
#                                           so folding it is order-preserving: 9.9p2 < 9.10p1 stays
#                                           9.9.2 < 9.10.1
# ONE derivation for the family. gen_appcast.sh (the appcast's <sparkle:version>) and
# previous-release-tag.sh (which release is the baseline) each carried their own, and when the pN rule
# was added to the appcast side only, every openssh tag fell outside previous-release-tag.sh's
# numeric() domain -- so it found no baseline, and no openssh release ever listed a moved ingredient.
# MavericksSparkle.cmake mirrors this in CMake (it cannot source sh); tests/version-lib-test.sh
# asserts the mirror keeps both transforms.
#
# A NON-monotonic suffix (-rc1, beta: the suffix means OLDER) must NOT be folded here -- 1.2.3rc1 ->
# 1.2.3.1 would sort ABOVE 1.2.3. Leave it unmapped so callers' numeric() checks fail closed.
comparison_key() {
  printf '%s' "$1" | sed -e 's/-mavericks\./\./' -e 's/\([0-9]\)p\([0-9]\)/\1.\2/'
}
