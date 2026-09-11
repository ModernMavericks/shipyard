#!/bin/sh
# delete-draft-release.sh removes the DRAFTS of exactly one tag -- the orphan a failed publish leaves --
# and nothing else: never a published release, never a draft of another tag. And a listing it cannot
# read is a failure, not "nothing to clean".
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
S="$here/../scripts/delete-draft-release.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/delete-draft.XXXXXX")"; trap 'rm -rf "$work"' EXIT  # template: 10.9 BSD mktemp requires one

# A stub gh: the listing prints $GH_PAGES (two pages, as --paginate does), DELETEs are logged.
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'SH'
#!/bin/sh
[ "${GH_FAIL:-}" = 1 ] && { echo "gh: HTTP 502" >&2; exit 1; }
case "$*" in
  "api -X DELETE "*) echo "$4" >> "$GH_LOG" ;;
  "api repos/"*"/releases?per_page=100 --paginate") cat "$GH_PAGES" ;;
  *) echo "stub gh: unexpected: $*" >&2; exit 3 ;;
esac
SH
chmod +x "$work/bin/gh"
cat > "$work/pages" <<'JSON'
[{"id": 11, "tag_name": "1.26.8-mavericks.3", "draft": true},
 {"id": 12, "tag_name": "1.26.8-mavericks.2", "draft": false}]
[{"id": 13, "tag_name": "1.26.8-mavericks.2", "draft": true},
 {"id": 14, "tag_name": "1.26.8-mavericks.3", "draft": true},
 {"id": 15, "tag_name": "1.26.8-mavericks.30", "draft": true}]
JSON
export GH_PAGES="$work/pages" GH_LOG="$work/log"
PATH="$work/bin:$PATH"; export PATH

# both drafts of the tag, across pages -- and neither the published .2, nor .2's draft, nor .30's
: > "$GH_LOG"
sh "$S" o/r 1.26.8-mavericks.3 >/dev/null
got="$(tr '\n' ' ' < "$GH_LOG")"
[ "$got" = "repos/o/r/releases/11 repos/o/r/releases/14 " ] \
  || { echo "FAIL expected drafts 11 and 14 of .3 deleted, got: $got"; exit 1; }

# a tag whose only release is published: nothing is deleted
: > "$GH_LOG"
out="$(sh "$S" o/r 1.26.8-mavericks.9)"
[ ! -s "$GH_LOG" ] || { echo "FAIL deleted something for a tag with no draft: $(cat "$GH_LOG")"; exit 1; }
printf '%s\n' "$out" | grep -q 'no draft release' || { echo "FAIL should say there was no draft: $out"; exit 1; }
: > "$GH_LOG"
sh "$S" o/r 1.26.8-mavericks.2 >/dev/null
[ "$(cat "$GH_LOG")" = "repos/o/r/releases/13" ] \
  || { echo "FAIL only .2's draft (13), never its published release (12): $(cat "$GH_LOG")"; exit 1; }

# a listing that fails must fail -- not read as "no drafts"
: > "$GH_LOG"
if GH_FAIL=1 sh "$S" o/r 1.26.8-mavericks.3 >/dev/null 2>&1; then
  echo "FAIL a failed listing should fail, not pass as nothing-to-clean"; exit 1
fi

echo "PASS: delete-draft-release"
