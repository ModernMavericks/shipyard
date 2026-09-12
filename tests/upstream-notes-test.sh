#!/bin/sh
# upstream-notes.sh: link upstream's own release notes when -- and only when -- a release ships an
# upstream version no earlier release shipped. The URL comes from the repo's own hook script.
set -eu
work="$(mktemp -d "${TMPDIR:-/tmp}/upstream-notes.XXXXXX")"; trap 'rm -rf "$work"' EXIT
here="$(cd "$(dirname "$0")" && pwd)"
S="$here/../scripts/upstream-notes.sh"
w="$(mktemp -d "${TMPDIR:-/tmp}/upstream-notes-t.XXXXXX")"; trap 'rm -rf "$w" "$work"' EXIT
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

# a repo that keeps its scripts in scripts/ (the swift repos) keeps the hook there too; build/ wins
mkdir -p scripts
printf '#!/bin/sh\nprintf "https://example.com/from-scripts/%%s\\n" "$1"\n' > scripts/upstream-release-notes-url.sh
mv build/upstream-release-notes-url.sh build/hook.keep
out="$(sh "$S" 1.1.0-mavericks.1)"
printf '%s\n' "$out" | grep -qF 'https://example.com/from-scripts/1.1.0' || { echo "FAIL scripts/: $out"; exit 1; }
mv build/hook.keep build/upstream-release-notes-url.sh
out="$(sh "$S" 1.1.0-mavericks.1)"
printf '%s\n' "$out" | grep -qF 'https://example.com/releases/v1.1.0' || { echo "FAIL build/ should win: $out"; exit 1; }
rm -r scripts

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

# --url-only: the generator puts the URL in its own sentence, and must distinguish "no link is due"
# from "the link is broken". Everything returning 0 is how signal-desktop's 8.27.0-mavericks.1 shipped
# a NEW upstream with no link and nothing red.
mk_repo_with_hook() {   # $1 = dir, $2 = hook body
  mkdir -p "$1/build"; ( cd "$1" && git init -q -b main . \
    && git config user.email t@example.com && git config user.name tester \
    && echo x > f && git add f && git commit -qm base )
  printf '%s\n' "$2" > "$1/build/upstream-release-notes-url.sh"
}

u1="$work/u-new"
mk_repo_with_hook "$u1" '#!/bin/sh
printf "https://example.com/notes/%s\n" "$1"'
( cd "$u1" && git tag 1.2.3-mavericks.1 )
out="$(cd "$u1" && MAVERICKS_ROOT="$u1" sh "$S" --url-only 1.2.3-mavericks.1)" && rc=0 || rc=$?
[ "$rc" = 0 ] && [ "$out" = "https://example.com/notes/1.2.3" ] \
  || { echo "FAIL --url-only new upstream: rc=$rc out='$out'"; exit 1; }

# a repackage: an earlier -mavericks.N of the same upstream exists -> exit 3, no output
( cd "$u1" && git tag 1.2.3-mavericks.2 )
out="$(cd "$u1" && MAVERICKS_ROOT="$u1" sh "$S" --url-only 1.2.3-mavericks.2 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" = 3 ] && [ -z "$out" ] || { echo "FAIL --url-only repackage: rc=$rc out='$out'"; exit 1; }

# no hook at all -> exit 4
u2="$work/u-nohook"
mk_repo_with_hook "$u2" '#!/bin/sh
exit 0'
rm "$u2/build/upstream-release-notes-url.sh"
( cd "$u2" && git tag 1.2.3-mavericks.1 )
( cd "$u2" && MAVERICKS_ROOT="$u2" sh "$S" --url-only 1.2.3-mavericks.1 >/dev/null 2>&1 ) && rc=0 || rc=$?
[ "$rc" = 4 ] || { echo "FAIL --url-only no hook: rc=$rc"; exit 1; }

# a hook that prints junk -> exit 5 (NOT 0: a broken link must be distinguishable from no link)
u3="$work/u-junk"
mk_repo_with_hook "$u3" '#!/bin/sh
echo not-a-url'
( cd "$u3" && git tag 1.2.3-mavericks.1 )
( cd "$u3" && MAVERICKS_ROOT="$u3" sh "$S" --url-only 1.2.3-mavericks.1 >/dev/null 2>&1 ) && rc=0 || rc=$?
[ "$rc" = 5 ] || { echo "FAIL --url-only junk hook: rc=$rc"; exit 1; }

# the DEFAULT mode is unchanged: section or nothing, always 0
out="$(cd "$u3" && MAVERICKS_ROOT="$u3" sh "$S" 1.2.3-mavericks.1 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] || { echo "FAIL default mode changed: rc=$rc out='$out'"; exit 1; }

# a shallow clone hides the tags: an unknown tag list must NOT read as "no earlier release" (that
# is exactly how a repackage gets called new). --url-only cannot honestly report "no link due" over
# an unknown tag list, so it must bail 5; default mode still prints nothing and exits 0 -- the mode
# split IS the point signal-desktop's incident turned on, so both halves need to be proven together.
u4="$work/u-shallow-src"
mk_repo_with_hook "$u4" '#!/bin/sh
printf "https://example.com/notes/%s\n" "$1"'
( cd "$u4" && git tag 1.2.3-mavericks.1 && git commit -q --allow-empty -m later )
u4s="$work/u-shallow"
git clone -q --depth 1 "file://$u4" "$u4s"
[ -z "$(git -C "$u4s" tag)" ] || { echo "FAIL fixture: shallow clone carried tags"; exit 1; }
mkdir -p "$u4s/build"; cp "$u4/build/upstream-release-notes-url.sh" "$u4s/build/"

( cd "$u4s" && MAVERICKS_ROOT="$u4s" sh "$S" --url-only 1.2.3-mavericks.1 >/dev/null 2>&1 ) && rc=0 || rc=$?
[ "$rc" = 5 ] || { echo "FAIL --url-only shallow clone: rc=$rc"; exit 1; }

out="$(cd "$u4s" && MAVERICKS_ROOT="$u4s" sh "$S" 1.2.3-mavericks.1 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] || { echo "FAIL default mode shallow clone changed: rc=$rc out='$out'"; exit 1; }

echo "PASS: upstream-notes"
