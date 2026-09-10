#!/bin/sh
# upstream-notes.sh: link upstream's own release notes when -- and only when -- a release ships an
# upstream version no earlier release shipped. The URL comes from the repo's own hook script.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
S="$here/../scripts/upstream-notes.sh"
w="$(mktemp -d "${TMPDIR:-/tmp}/upstream-notes-t.XXXXXX")"; trap 'rm -rf "$w"' EXIT
cd "$w"
git init -q -b main .
git config user.email t@example.com; git config user.name tester
printf 'x\n' > README
git add -A; git commit -qm base
git tag 1.0.0-mavericks.1; git tag 1.0.0-mavericks.2
export MAVERICKS_ROOT="$w"

# no hook -> nothing, successfully (a repo that has not adopted it, or a self-upstream repo)
out="$(sh "$S" 1.1.0-mavericks.1)"
[ -z "$out" ] || { echo "FAIL no-hook: got '$out'"; exit 1; }

mkdir -p build
printf '#!/bin/sh\nprintf "https://example.com/releases/v%%s\\n" "$1"\n' > build/upstream-release-notes-url.sh

# a repackage of an upstream already shipped -> nothing
out="$(sh "$S" 1.0.0-mavericks.3)"
[ -z "$out" ] || { echo "FAIL repackage: got '$out'"; exit 1; }

# a new upstream -> a section linking upstream's notes for THAT version
out="$(sh "$S" 1.1.0-mavericks.1)"
printf '%s\n' "$out" | grep -qx '### Upstream' || { echo "FAIL header: $out"; exit 1; }
printf '%s\n' "$out" | grep -qxF -- '- [Upstream release notes for 1.1.0](https://example.com/releases/v1.1.0)' \
  || { echo "FAIL link: $out"; exit 1; }

# a tag-triggered build already has its own tag: that tag is not an EARLIER release of the upstream
git tag 1.1.0-mavericks.1
out="$(sh "$S" 1.1.0-mavericks.1)"
printf '%s\n' "$out" | grep -qF 'https://example.com/releases/v1.1.0' \
  || { echo "FAIL own tag counted as earlier: $out"; exit 1; }
out="$(sh "$S" 1.1.0-mavericks.2)"
[ -z "$out" ] || { echo "FAIL repackage after tag: got '$out'"; exit 1; }

# 1.1.0 must not be mistaken for a repackage of 1.1.0.1 or 11.1.0 (glob is the whole upstream)
git tag 1.1.0.1-mavericks.1
out="$(sh "$S" 1.1-mavericks.1)"
printf '%s\n' "$out" | grep -qF 'https://example.com/releases/v1.1)' \
  || { echo "FAIL prefix collision: $out"; exit 1; }

# tags it cannot see must not read as "no earlier release": that would call every repackage new.
# A shallow clone has no tags at all, and a git that refuses the repo lists none.
git commit -q --allow-empty -m later     # releases are tagged BEHIND the tip, as in real history
git clone -q --depth 1 "file://$w" "$w/shallow"
[ -z "$(git -C "$w/shallow" tag)" ] || { echo "FAIL fixture: shallow clone carried tags"; exit 1; }
mkdir -p "$w/shallow/build"; cp build/upstream-release-notes-url.sh "$w/shallow/build/"
out="$(MAVERICKS_ROOT="$w/shallow" sh "$S" 1.0.0-mavericks.3 2>"$w/err")"
[ -z "$out" ] || { echo "FAIL shallow clone called a repackage new: $out"; exit 1; }
grep -q 'upstream-notes' "$w/err" || { echo "FAIL shallow not warned"; exit 1; }
mkdir -p "$w/not-a-repo/build"; cp build/upstream-release-notes-url.sh "$w/not-a-repo/build/"
out="$(cd "$w/not-a-repo" && MAVERICKS_ROOT="$w/not-a-repo" GIT_CEILING_DIRECTORIES="$w" \
        sh "$S" 1.0.0-mavericks.3 2>"$w/err")"
[ -z "$out" ] || { echo "FAIL unlistable tags called a repackage new: $out"; exit 1; }
grep -q 'upstream-notes' "$w/err" || { echo "FAIL unlistable tags not warned"; exit 1; }
rm -rf "$w/shallow" "$w/not-a-repo"

# the first release a repo ever cuts ships a new upstream too
git tag | xargs git tag -d >/dev/null
out="$(sh "$S" 2.0.0-mavericks.1)"
printf '%s\n' "$out" | grep -qF 'https://example.com/releases/v2.0.0' || { echo "FAIL first: $out"; exit 1; }

# notes are prose: a failing hook warns and drops the section, it never fails the release
printf '#!/bin/sh\necho "upstream changelog unreachable" >&2\nexit 3\n' > build/upstream-release-notes-url.sh
out="$(sh "$S" 3.0.0-mavericks.1 2>"$w/err")" || { echo "FAIL hook failure failed the caller"; exit 1; }
[ -z "$out" ] || { echo "FAIL hook-fail output: $out"; exit 1; }
grep -q 'unreachable' "$w/err" || { echo "FAIL hook's own stderr swallowed"; cat "$w/err"; exit 1; }
grep -q 'upstream-notes' "$w/err" || { echo "FAIL no warning of our own"; cat "$w/err"; exit 1; }

# ...and so does one that prints something that is not a single URL
printf '#!/bin/sh\necho "see the website"\n' > build/upstream-release-notes-url.sh
out="$(sh "$S" 3.0.0-mavericks.1 2>"$w/err")"
[ -z "$out" ] || { echo "FAIL non-url output: $out"; exit 1; }
grep -q 'upstream-notes' "$w/err" || { echo "FAIL non-url not warned"; exit 1; }
printf '#!/bin/sh\n:\n' > build/upstream-release-notes-url.sh
out="$(sh "$S" 3.0.0-mavericks.1 2>"$w/err")"
[ -z "$out" ] || { echo "FAIL empty output: $out"; exit 1; }
grep -q 'upstream-notes' "$w/err" || { echo "FAIL empty not warned"; exit 1; }

echo "PASS: upstream-notes"
