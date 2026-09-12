#!/bin/sh
# Print what this product declares itself to BE, for release purposes: one line per entry,
# "<name><TAB><path>" or "<name><TAB><path>:<KEY>", in declaration order.
#
# A release is the realisation of a declared state, not the side effect of an event (spec
# 2026-09-12). This is where "declared" is defined. It lives in INGREDIENTS.md -- the file that
# already documents what a product is made of, and already carries a machine-readable section with a
# strict grammar (## Conformance deviations, parsed by deviations.sh). A separate declaration file
# would be a second list of the same pins, and two lists drift.
#
# INGREDIENTS.md, "## Declared state" -- what this product declares itself to BE, for release
# purposes. One entry per line, in the same shape as the "## Conformance deviations" section:
#   - <canonical-name>: <path>          the whole file's contents, whitespace-trimmed
#   - <canonical-name>: <path>:<KEY>    the value assigned to KEY inside that file
# Exactly one entry must be named `upstream`. Names are canonical and stable: renaming a pin FILE
# must not change the digest, so the digest is keyed on the name, never the path. A product that IS
# its own source points `upstream` at the version file it commits.
#
# AUTHORITATIVE for release identity, and deliberately a SUBSET of the prose table above it: that
# table documents everything baked in, including things that must never cut a release (bats; an SDK
# pinned by hash that will never move). Prose explains; this section decides.
#
# No section, or no INGREDIENTS.md: exit 0 silently -- a repo that has not migrated is not an error,
# which is what lets this whole design roll out one repo at a time. A MALFORMED entry is fatal
# (exit 1) and names itself: a declaration nobody can read must not become a digest.
#   usage: declared-state.sh [repo-root]
set -eu
root="${1:-.}"
[ -f "$root/INGREDIENTS.md" ] || exit 0

sed -n '/^## Declared state/,/^## /p' "$root/INGREDIENTS.md" | awk '
  # "- <name>: <rest>" -- the same entry shape deviations.sh reads, so one file means one thing.
  /^- *[^:]+:/ {
    line = $0; sub(/^- */, "", line)
    i = index(line, ":"); name = substr(line, 1, i - 1); rest = substr(line, i + 1)
    sub(/^ */, "", rest); sub(/ *$/, "", rest)
    gsub(/ /, "", name)

    if (name !~ /^[a-z0-9][a-z0-9._-]*$/) {
      print "declared-state.sh: \"" name "\" is not a canonical name (lowercase, digits, . _ -)" > "/dev/stderr"
      bad = 1; next
    }
    if (rest == "") {
      print "declared-state.sh: \"" name "\" declares no path" > "/dev/stderr"
      bad = 1; next
    }
    if (name in seen) {
      print "declared-state.sh: \"" name "\" is declared twice -- one name, one value" > "/dev/stderr"
      bad = 1; next
    }
    seen[name] = 1
    if (name == "upstream") { has_upstream = 1 }
    printf "%s\t%s\n", name, rest
    n++
    next
  }
  END {
    if (n > 0 && !has_upstream) {
      print "declared-state.sh: no \"upstream\" entry -- every product declares one: the upstream it" > "/dev/stderr"
      print "  wraps, or (for a product that IS its own source) the version file it commits" > "/dev/stderr"
      bad = 1
    }
    if (bad) exit 1
  }
'
