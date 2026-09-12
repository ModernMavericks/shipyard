#!/bin/sh
# Guard the ingredient pin declaration. The notes and the repackage trigger read ONE list
# (ingredient-pins.sh), so they cannot disagree -- but a list can still be wrong on its own:
# a typo'd glob that matches nothing, or a caller whose every watched path is own-upstream, both
# yield silently thinner release notes and a repackage that never fires. Fail loudly instead.
# A repo with no caller workflow has no ingredients and passes trivially.
#   usage: check-ingredient-pins.sh [caller-workflow-path]
set -eu
SELF="$(cd "$(dirname "$0")" && pwd)"
caller="${1:-.github/workflows/repackage-on-ingredient-bump.yml}"

if [ ! -f "$caller" ]; then
  echo "check-ingredient-pins: no $caller — repo declares no build ingredients, nothing to check"
  exit 0
fi

pins="$(sh "$SELF/ingredient-pins.sh" "$caller")"
if [ -z "$pins" ]; then
  echo "check-ingredient-pins: $caller watches paths, but none expand to a tracked ingredient pin." >&2
  echo "  Either a glob matches nothing (typo?), or every watched path is own-upstream-paths." >&2
  exit 1
fi

status=0
for p in $pins; do
  # A "path:KEY" entry (ingredient-pins.sh's own-upstream-paths key form) names a tracked FILE plus a
  # key excluded from it -- only the path half is a git path, so strip the key before testing it.
  path="${p%%:*}"
  git ls-files --error-unmatch "$path" >/dev/null 2>&1 || {
    echo "check-ingredient-pins: pin '$p' is not tracked in git; notes read pin history from git" >&2
    status=1
  }
done

[ "$status" -eq 0 ] && printf 'check-ingredient-pins: ok — %s\n' "$(printf '%s' "$pins" | tr '\n' ' ')"
exit "$status"
