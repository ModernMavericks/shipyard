#!/bin/sh
# Print this repo's build-ingredient pin paths, one per line.
#
# Source of truth is the repo's OWN repackage caller: the paths it watches are the ingredient pins,
# minus own-upstream-paths (a new upstream is not an ingredient). Deriving the list here instead of
# maintaining a second copy is what makes the repackage trigger and the release notes impossible to
# drift apart. Globs are expanded against tracked files, so 'components/**' becomes real paths.
# A repo with no caller (no ingredients) prints nothing and exits 0.
#
# own-upstream-paths entries come in the same two forms repackage-decision.sh understands: a bare PATH
# excludes that whole file, and a "path:KEY" entry (the swift repos' shape: every pin lives in one
# pins.env/build.sh, and only SWIFT_VERSION is their own upstream) excludes just that KEY, printed
# here as "path:KEY" so ingredient-notes.sh can exclude the same one key while still reporting the
# file's other, genuinely-ingredient keys.
#   usage: ingredient-pins.sh [caller-workflow-path]
set -eu
caller="${1:-.github/workflows/repackage-on-ingredient-bump.yml}"
[ -f "$caller" ] || exit 0

# Both YAML forms the family uses:  paths: ['a', 'b']  and  paths:\n  - a  # comment
# \047 is a single quote (awk source can't hold one inside a single-quoted shell argument).
patterns="$(awk '
  /^[[:space:]]*paths:[[:space:]]*\[/ {
    line = $0; sub(/^[^[]*\[/, "", line); sub(/\].*$/, "", line)
    n = split(line, a, ",")
    for (i = 1; i <= n; i++) { gsub(/[ \t\047"]/, "", a[i]); if (a[i] != "") print a[i] }
    next
  }
  /^[[:space:]]*paths:[[:space:]]*$/ { inblock = 1; next }
  inblock {
    if ($0 ~ /^[[:space:]]*-[[:space:]]*/) {
      v = $0; sub(/^[[:space:]]*-[[:space:]]*/, "", v); sub(/[[:space:]]*#.*$/, "", v)
      gsub(/[ \t\047"]/, "", v); if (v != "") print v
      next
    }
    inblock = 0
  }
' "$caller")"
[ -n "$patterns" ] || exit 0

own="$(sed -n 's/^[[:space:]]*own-upstream-paths:[[:space:]]*//p' "$caller" \
        | sed 's/[[:space:]]*#.*$//' | tr -d '"'"'"'')"

# Expand each pattern against tracked files. GitHub's '**' and sh's '*' both cross directory
# separators in a case pattern, so '**' collapses to '*'.
#
# set -f is load-bearing: unquoted $patterns is word-split AND pathname-expanded, so 'components/**'
# would silently become the DIRECTORY names it matches on disk (components/golang, ...) instead of
# staying a pattern. Noglob leaves `case` matching untouched, which is where globbing belongs here.
set -f
for f in $(git ls-files); do
  for p in $patterns; do
    pat="$(printf '%s' "$p" | sed 's/\*\*/*/g')"
    # shellcheck disable=SC2254  # $pat is intentionally a glob
    case "$f" in
      $pat) ;;
      *) continue ;;
    esac
    excluded=no
    exclkey=""
    for o in $own; do
      case "$o" in
        *:*)
          ofile="${o%%:*}"; okey="${o##*:}"
          [ "$f" = "$ofile" ] && exclkey="$okey"
          ;;
        *)
          [ "$f" = "$o" ] && { excluded=yes; break; }
          ;;
      esac
    done
    if [ "$excluded" = yes ]; then
      :
    elif [ -n "$exclkey" ]; then
      printf '%s:%s\n' "$f" "$exclkey"
    else
      printf '%s\n' "$f"
    fi
    break
  done
done
