#!/bin/sh
# Gate: no shell construct that the 10.9 base system lacks, in the scripts this family ships.
#
# These all share one shape: they work on a CI runner and fail on the platform the family exists to
# support. CI is therefore structurally incapable of catching them, which is how two of them shipped
# from shipyard itself and reached every consumer through @v1:
#
#   - `sort -V` in previous-release-tag.sh: 10.9's sort exits 2 printing nothing, and
#     release-notes-file.sh swallows that (`2>/dev/null || true`) into an EMPTY "changed since"
#     baseline. Release notes silently diffed against nothing. Green in CI the whole time.
#   - a bare `mktemp -d` in run-repo-tests.sh and 12 test files: 10.9 mktemp demands a template, so
#     the test runner died on its own logfile and the suite could not START on 10.9.
#
# It also bans the assertion forms that CANNOT FAIL there, which is worse than failing: a bare
# `[[ ]]` mid-test (bash < 4.1 -- 10.9's /bin/bash, which pkgsrc's bats runs under -- does not let it
# fail the test) and a bare `! cmd` (no bash lets errexit see it). ed25519's suite carried fourteen of
# the first kind and one test that only passed on `env`'s usage error; all of them green on 10.9.
# A `! cmd` line continued with a trailing backslash is skipped: a line-based lint cannot see whether
# the `|| fail` is on the next line (porthole's are), so there it trusts the author.
#
# Adding a rule is one line in the table. Each rule carries a SAMPLE it must still match, asserted
# before any scan: a lint whose pattern quietly stopped matching is green forever AND stops anyone
# from looking, which is strictly worse than no lint.
#
# Scans the repo's git-TRACKED *.sh and *.bats (so vendored or fetched upstream trees, which we do
# not get to rewrite, are out of scope), or exactly the files named on the command line. .bats counts
# because it IS shell: the first cut of this lint checked only *.sh and therefore reported ed25519
# clean while tests/version.bats died on a bare `mktemp -d` in its setup() -- a green lint sitting
# next to the exact bug it exists to catch.
#   usage: check-shell-portability.sh [file ...]
set -eu

# pattern<TAB>sample-it-must-match<TAB>what<TAB>what to do instead
rulesfile="$(mktemp "${TMPDIR:-/tmp}/shell-portability.XXXXXX")"
trap 'rm -f "$rulesfile"' EXIT
cat > "$rulesfile" <<'RULES'
sort[[:space:]]+(-[A-Za-z]*V\b|--version-sort)	git tag --list | sort -V | tail -1	sort -V	compare numerically instead (shipyard's lib.sh ver_cmp; see previous-release-tag.sh) -- 10.9's BSD sort has no -V and exits 2 having printed NOTHING, so a caller that swallows stderr gets a silently empty result
\$\(mktemp([[:space:]]+-[A-Za-z]+)*[[:space:]]*\)	work="$(mktemp -d)"	mktemp with no template	give it one: mktemp -d "${TMPDIR:-/tmp}/<name>.XXXXXX" -- 10.9 BSD mktemp rejects a bare -d with a usage error
lipo[^|;&]*[[:space:]]-archs\b	for a in $(lipo -archs "$b"); do	lipo -archs	use `lipo -info "$f" | sed -n 's/.*: //p'` (add | xargs when comparing for an EXACT arch set) -- 10.9's lipo has no -archs and dies "unknown flag: -archs". -info exists on every macOS; sed -n ...p prints only the line that names the archs, which matters because 10.9's lipo also prints "input file X is not a fat file" to STDOUT for a thin file, and a plain s/.*: // would pass that noise straight through
^[[:space:]]*\[\[[[:space:]].*\]\][[:space:]]*(#.*)?$|\]\][[:space:]]*;[[:space:]]*done	  [[ "$output" == *"<li>one</li>"* ]]	a bare [[ ]] assertion	end it `|| false` (what bats documents for this) -- on bash < 4.1, 10.9's /bin/bash and the one pkgsrc's bats runs under, a failing [[ ]] that is not the last command of a test does NOT fail it, so on 10.9 the assertion checks nothing
^[[:space:]]*![[:space:]]([^|&]|\|[^|]|&[^&])*[^\\|&]$	  ! echo "$output" | grep -q 'tag v1)'	a bare !-negated command	end it `|| false`, or in bats write `run ! cmd` -- on ANY bash a !-negated command never trips errexit, so anywhere but a test's last line it checks nothing
RULES

TAB="$(printf '\t')"
status=0

# Every rule must still match its own sample, or the lint is dead rather than clean.
while IFS="$TAB" read -r pat sample what instead; do
  [ -n "$pat" ] || continue
  printf '%s\n' "$sample" | grep -qE "$pat" || {
    echo "check-shell-portability: the rule for '$what' no longer matches its own sample -- the lint is dead, not clean" >&2
    echo "    fix: repair the pattern, or drop the rule deliberately" >&2
    status=1
  }
done < "$rulesfile"

if [ "$#" -gt 0 ]; then
  files="$*"
elif git rev-parse --git-dir >/dev/null 2>&1; then
  files="$(git ls-files '*.sh' '*.bats' 2>/dev/null || true)"
else
  echo "check-shell-portability: not a git checkout and no files named -- nothing scanned" >&2
  echo "    fix: run it in the repo, or pass the files to scan" >&2
  exit 1
fi

# Full-line comments are stripped first, so the prose explaining a ban is not itself a violation.
# A line carrying `portability-ok:` plus a reason is exempt too -- the same escape hatch, and the same
# obligation to justify it, as the `# shellcheck disable=... # <reason>` lines already in this tree.
# It exists mainly for the lint's OWN test fixtures, which must contain violations to be worth
# anything; a reason is required so silencing one stays a visible choice in review rather than a
# quiet deletion. sed preserves the line count, so grep -n still reports the real line number.
while IFS="$TAB" read -r pat sample what instead; do
  [ -n "$pat" ] || continue
  for f in $files; do
    [ -f "$f" ] || continue
    # This file's own rule table holds the samples, which are by construction violations.
    [ "$(basename "$f")" = "$(basename "$0")" ] && continue
    hits="$(sed -e 's/^[[:space:]]*#.*//' -e '/portability-ok:[[:space:]]*[^[:space:]]/s/.*//' "$f" | grep -nE "$pat" || true)"
    [ -n "$hits" ] || continue
    printf '%s\n' "$hits" | while IFS= read -r h; do
      echo "check-shell-portability: $f:${h%%:*} uses $what -- a hazard on 10.9" >&2
    done
    echo "    fix: $instead" >&2
    status=1
  done
done < "$rulesfile"

[ "$status" -eq 0 ] || exit 1
echo "check-shell-portability: ok — no 10.9-unavailable constructs"
