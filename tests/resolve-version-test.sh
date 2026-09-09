#!/bin/sh
# resolve-version.sh: the ONE way a repo learns its full version at build time.
#
# Exists because the family had three answers to "what version is this?" -- a committed VERSION file
# (which drifted: container-tools shipped .14 while its file said .2), a tag, or a derivation from
# tags -- and a build could pick a different one than the release did. Now every repo asks this, and
# the shipped state (tags) is the only authority. VERSION is a build product, not an input.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
S="$here/../scripts/resolve-version.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/resolve-version-test.XXXXXX")"; trap 'rm -rf "$work"' EXIT

new_repo() {  # $1 = dir, $2 = upstream version
  mkdir -p "$work/$1"
  printf '%s\n' "$2" > "$work/$1/UPSTREAM_VERSION"
}

# A repo with no VERSION file derives one from UPSTREAM_VERSION + the shipped tags, and WRITES it so
# the rest of the build (cmake configure, the updater bundle) reads the same string.
new_repo a 1.5.2
out="$(MAVERICKS_ROOT="$work/a" MAVERICKS_TAGS="1.5.2-mavericks.1
1.5.2-mavericks.3" sh "$S")"
[ "$out" = "1.5.2-mavericks.3" ] || { echo "FAIL derive from tags: got '$out'"; exit 1; }
[ "$(cat "$work/a/VERSION")" = "1.5.2-mavericks.3" ] || { echo "FAIL should write VERSION"; exit 1; }

# An existing VERSION file is a build product from earlier in THIS build, so it is reused as-is --
# every job in a run must agree, and re-deriving could pick up a tag pushed mid-run.
printf '9.9.9-mavericks.9\n' > "$work/a/VERSION"
out="$(MAVERICKS_ROOT="$work/a" MAVERICKS_TAGS="" sh "$S")"
[ "$out" = "9.9.9-mavericks.9" ] || { echo "FAIL should reuse existing VERSION: got '$out'"; exit 1; }

# 'local' mode is a repackage of the shipped upstream: N+1, same upstream.
new_repo b 20260727
out="$(MAVERICKS_ROOT="$work/b" MAVERICKS_TAGS="20260727-mavericks.14" sh "$S" local)"
[ "$out" = "20260727-mavericks.15" ] || { echo "FAIL local repackage: got '$out'"; exit 1; }

# A brand-new upstream has no tags yet -> N=1.
new_repo c 2.0.0
out="$(MAVERICKS_ROOT="$work/c" MAVERICKS_TAGS="1.9.0-mavericks.7" sh "$S")"
[ "$out" = "2.0.0-mavericks.1" ] || { echo "FAIL new upstream: got '$out'"; exit 1; }

# An EMPTY VERSION file must fail loudly rather than yield an empty version. A build that names its
# artifacts "-mavericks." with nothing in front produces garbage that looks almost right.
new_repo d 1.0.0
: > "$work/d/VERSION"
if out="$(MAVERICKS_ROOT="$work/d" MAVERICKS_TAGS="" sh "$S" 2>&1)"; then
  echo "FAIL empty VERSION should fail; got '$out'"; exit 1
fi
printf '%s\n' "$out" | grep -qi 'empty' || { echo "FAIL should say VERSION is empty: $out"; exit 1; }

# No UPSTREAM_VERSION and no VERSION: say which file is missing, not "cannot open".
mkdir -p "$work/e"
if out="$(MAVERICKS_ROOT="$work/e" MAVERICKS_TAGS="" sh "$S" 2>&1)"; then
  echo "FAIL missing UPSTREAM_VERSION should fail; got '$out'"; exit 1
fi
printf '%s\n' "$out" | grep -q 'UPSTREAM_VERSION' || { echo "FAIL should name UPSTREAM_VERSION: $out"; exit 1; }

# A repo with parallel upstream lines (golang) keeps one UPSTREAM_VERSION per line, so the file to
# read is an input. Same override the shared version.sh already honors.
mkdir -p "$work/f/lines/127"
printf '1.27.0\n' > "$work/f/lines/127/UPSTREAM_VERSION"
out="$(MAVERICKS_ROOT="$work/f" MAVERICKS_UPSTREAM_FILE="$work/f/lines/127/UPSTREAM_VERSION" \
       MAVERICKS_TAGS="1.27.0-mavericks.2" sh "$S")"
[ "$out" = "1.27.0-mavericks.2" ] || { echo "FAIL per-line upstream: got '$out'"; exit 1; }

echo "PASS: resolve-version"
