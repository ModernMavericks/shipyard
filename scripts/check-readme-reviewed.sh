#!/bin/sh
# Refuse a repo's FIRST EVER release until a human has edited its README. A generated README is
# fine to develop against and wrong to publish: it is the page every visitor lands on, and nobody
# reads their own project's front door until something forces them to. Publishing is that moment.
#
# The test is a marker line the generated README carries, in plain visible prose under the heading,
# NOT an HTML comment -- so it renders on the repo's front page, where leaving it in place is
# embarrassing rather than invisible. A human edits the README, deletes the line, and the gate
# passes forever after. Nothing here inspects git history: authorship cannot distinguish a human's
# edit from an assistant's commit of a human's words, and a shallow CI checkout has no history to
# inspect anyway.
#
# Only the first release is gated. A repo that has published before has a README somebody shipped;
# this convention exists to stop the first one going out unread, not to police later edits.
#   usage: check-readme-reviewed.sh [readme-path]
set -eu
readme="${1:-README.md}"

# The substring the gate keys on, deliberately shorter than the sentence around it, so a repo can
# word its own marker to taste without breaking the check.
MARKER='not been read or edited by a human'

if [ ! -f "$readme" ]; then
  echo "check-readme-reviewed: no $readme to check" >&2
  echo "    fix: add one. A repo publishing its first release with no README at all is worse than" >&2
  echo "         one publishing a generated README." >&2
  exit 1
fi

if grep -qF "$MARKER" "$readme"; then
  echo "check-readme-reviewed: $readme still carries the unreviewed marker, so no human has edited it" >&2
  echo "    fix: read $readme, make it say what this project is and how to use it, and delete the" >&2
  echo "         marker line. That line is visible on the repo's front page; shipping it is the" >&2
  echo "         thing this gate exists to prevent." >&2
  exit 1
fi

echo "check-readme-reviewed: ok — $readme carries no unreviewed marker"
