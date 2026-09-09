#!/bin/sh
# Gate: no shell construct that the 10.9 base system lacks, in the scripts this family INSTALLS and
# runs there. Every one of these works on a CI runner and fails on the platform the family exists to
# support, so CI cannot be the thing that catches them -- which is exactly how two of them shipped:
#
#   - `sort -V` in previous-release-tag.sh: 10.9's sort exits 2 printing nothing, and
#     release-notes-file.sh swallows that (`2>/dev/null || true`) into an EMPTY "changed since"
#     baseline. Notes silently diffed against nothing. Green in CI the whole time.
#   - a bare `mktemp -d` in run-repo-tests.sh and 12 test files: 10.9 mktemp demands a template, so
#     the runner died on its own logfile and the suite could not start on 10.9 at all. That is what
#     let a stale fixture in check-family-conventions-test.sh go unseen -- CI died earlier, and the
#     one machine that would have caught it could not run the suite.
#
# Adding a rule is one line in the table below. Each rule carries a SAMPLE it must still match, and
# the sample is asserted first: a lint whose pattern quietly stopped matching is green forever and
# worse than no lint, since it also stops anyone from looking.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
self="$(basename "$0")"

# pattern<TAB>sample-it-must-match<TAB>what<TAB>what to do instead
rulesfile="$(mktemp "${TMPDIR:-/tmp}/portability-rules.XXXXXX")"
trap 'rm -f "$rulesfile"' EXIT
cat > "$rulesfile" <<'RULES'
sort[[:space:]]+(-[A-Za-z]*V\b|--version-sort)	git tag --list | sort -V | tail -1	sort -V	source lib.sh and compare with ver_cmp() -- 10.9's BSD sort has no -V and exits 2 having printed NOTHING, which callers that swallow stderr turn into a silently empty result (see previous-release-tag.sh)
\$\(mktemp([[:space:]]+-[A-Za-z]+)*[[:space:]]*\)	work="$(mktemp -d)"	mktemp with no template	give it one: mktemp -d "${TMPDIR:-/tmp}/<name>.XXXXXX" -- 10.9 BSD mktemp rejects a bare -d with a usage error
RULES

status=0

# 1. Every rule must still match its own sample.
while IFS="$(printf '\t')" read -r pat sample what instead; do
  [ -n "$pat" ] || continue
  printf '%s\n' "$sample" | grep -qE "$pat" || {
    echo "portability: the rule for '$what' no longer matches its own sample -- the lint is dead, not clean" >&2
    echo "    sample: $sample" >&2
    echo "    fix: repair the pattern, or drop the rule deliberately" >&2
    status=1
  }
done < "$rulesfile"

# 2. Nothing in the shipped scripts (or the tests that must run on 10.9) may use one.
# Full-line comments are stripped first, so the prose explaining a ban is not itself a violation;
# sed keeps the line count, so grep -n still reports the real line number.
while IFS="$(printf '\t')" read -r pat sample what instead; do
  [ -n "$pat" ] || continue
  for f in "$root"/scripts/*.sh "$root"/tests/*.sh; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = "$self" ] && continue
    hits="$(sed 's/^[[:space:]]*#.*//' "$f" | grep -nE "$pat" || true)"
    [ -n "$hits" ] || continue
    printf '%s\n' "$hits" | while IFS= read -r h; do
      echo "portability: ${f#"$root"/}:${h%%:*} uses $what" >&2
    done
    echo "    fix: $instead" >&2
    status=1
  done
done < "$rulesfile"

[ "$status" -eq 0 ] || exit 1
echo "PASS: portability-10-9"
