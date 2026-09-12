#!/bin/sh
# Print the deviations declared in <repo>/INGREDIENTS.md "## Conformance deviations", one per line:
#   <check> <glob or *> <reason>
# Grammar (unchanged from artifact-facts.sh): "- <check>[:<glob>]: <reason>". A deviation IS a product
# fact, so it lives with the other product facts; one parser keeps every checker reading it alike.
# Exit 1 if an entry has no reason: an exception without one is indistinguishable from drift.
#   usage: deviations.sh [repo-root]
set -eu
root="${1:-.}"
[ -f "$root/INGREDIENTS.md" ] || exit 0
sed -n '/^## Conformance deviations/,/^## /p' "$root/INGREDIENTS.md" | awk '
  /^- *[a-z][a-z0-9_-]*(:[^ :]*)? *:/ {
    line = $0; sub(/^- */, "", line)
    i = index(line, ":"); check = substr(line, 1, i - 1); rest = substr(line, i + 1)
    glob = "*"
    if (rest !~ /^ /) { j = index(rest, ":"); glob = substr(rest, 1, j - 1); rest = substr(rest, j + 1) }
    sub(/^ */, "", rest)
    if (rest == "") { print "deviations.sh: \"" check "\" declares no reason" > "/dev/stderr"; bad = 1; next }
    print check " " glob " " rest
  }
  END { exit bad }'
