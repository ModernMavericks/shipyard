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
    if (rest !~ /^ /) {
      j = index(rest, ":"); glob = substr(rest, 1, j - 1); rest = substr(rest, j + 1)
      # No second colon (j == 0) leaves an EMPTY glob -- "- check:reason", the same declaration
      # written without the space. It fails SAFE, which is what makes it worth rejecting rather than
      # tolerating: an empty glob matches no file, so the author has written an exception, the file
      # looks like it carries one, and no checker honours it. Worse, every reader that splits on
      # whitespace then takes the reason FIRST WORD as the scope. Reject it the same way a missing
      # reason is rejected: one grammar, one meaning.
      if (glob == "") {
        print "deviations.sh: \"" check "\" has an empty glob -- write \"- " check ": <reason>\" or \"- " check ":<glob>: <reason>\"" > "/dev/stderr"
        bad = 1; next
      }
    }
    sub(/^ */, "", rest)
    if (rest == "") { print "deviations.sh: \"" check "\" declares no reason" > "/dev/stderr"; bad = 1; next }
    print check " " glob " " rest
  }
  END { exit bad }'
