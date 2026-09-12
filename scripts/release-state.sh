#!/bin/sh
# Render this product's declared state canonically, and hash it.
#
# A release is the realisation of a declared state, not the side effect of an event (spec
# 2026-09-12). publish-release.yml records this digest in the release body; release-needed.sh looks
# it up. Two things to know before editing anything here:
#
#   1. The rendering is a WIRE FORMAT. Every published release carries a digest computed from it, so
#      changing the rendering makes every one of them stop matching -- which reads as "nothing has
#      ever been released". Hence the v1: prefix and the golden test. A format bump means RECOMPUTE,
#      never republish -- and --ref below is what makes recomputing possible: the digest of a state
#      that was already released is computed from the tag that released it, exactly, in any format.
#   2. Declared state EXCLUDES the source tree. That is what makes "a push causes feedback and almost
#      never a release" a property of the design rather than a rule someone must enforce.
#
# What is declared lives in INGREDIENTS.md's "## Declared state" section; declared-state.sh is the
# parser and documents the grammar.
#   usage: release-state.sh [--root DIR] [--ref REV] [--render]
#          --render  print the canonical rendering instead of its digest (debugging, and the test)
#          --ref     take each declared entry's VALUE from REV's tree instead of the working tree
set -eu
SELF="$(cd "$(dirname "$0")" && pwd)"

ROOT="."; RENDER=no; REF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2%/}"; shift 2;;
    --ref) REF="$2"; shift 2;;
    --render) RENDER=yes; shift;;
    *) echo "release-state: unknown option $1" >&2; exit 2;;
  esac
done

# --ref exists because INFERENCE WAS UNSOUND, and the inference it replaces lost releases silently.
# An earlier cut of release-needed.sh fell back to version equality -- "no digest anywhere, but a
# release exists for the version this state maps to, so it must already be released" -- and then
# backfilled the current digest onto that release. But version.sh's `auto` mode returns the EXISTING
# tag's N whenever the upstream already has one, so it maps EVERY declared state of a given upstream
# to ONE version. An ingredient bump that had not been released was therefore declared released, and
# the backfill cemented it: the digest of the unreleased state was written onto a release that did
# not contain it, after which the fast path matched and no later reconcile ever looked again. A
# release lost silently and permanently -- the golang incident, reproduced by the machinery built to
# prevent it, in a self-concealing form the original was not.
#
# So a released state is COMPUTED, not guessed: --ref <tag> renders the declaration using the values
# in that tag's own tree. The DECLARATION itself still comes from the working tree, deliberately --
# a pre-migration release predates the "## Declared state" section entirely, and the question being
# asked is "what were TODAY's declared inputs worth at that tag?". A path the tag's tree does not
# have is fatal, not empty (see the per-entry error below).
if [ -n "$REF" ]; then
  git -C "$ROOT" rev-parse --verify "$REF^{commit}" >/dev/null 2>&1 || {
    echo "release-state: --ref '$REF' is not a revision of the repo at $ROOT" >&2
    echo "    (a shallow clone can hide one: release work needs fetch-depth: 0 and visible tags)" >&2
    exit 2
  }
fi

# The value assigned to KEY in FILE, quotes and surrounding whitespace stripped, first match wins --
# the same shape repackage-decision.sh reads, so a pin file means one thing to every script in the
# family. Trimmed the same way the whole-file path is trimmed: two spellings of the same pin must
# render identically, or a cosmetic reformat would move the digest.
pin_value() {  # $1 = file  $2 = key
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1 | sed 's/^"//; s/"$//' | tr -d '[:space:]'
}

_tmp="${TMPDIR:-/tmp}"
work="$(mktemp -d "${_tmp%/}/release-state.XXXXXX")"; trap 'rm -rf "$work"' EXIT
decl="$work/decl"; lines="$work/lines"
: > "$lines"

# A parse failure must not become a digest, so take the parser's exit status before using its output.
# declared-state.sh's own contract is exit 1 on a malformed entry; convert that to release-state's
# documented exit 2 for any usage-or-declaration error, but keep its message so the author still
# learns which entry was wrong.
if ! sh "$SELF/declared-state.sh" "$ROOT" > "$decl" 2>"$work/parse-err"; then
  cat "$work/parse-err" >&2
  echo "release-state: $ROOT/INGREDIENTS.md has a malformed \"## Declared state\" declaration" >&2
  exit 2
fi
[ -s "$decl" ] || {
  echo "release-state: $ROOT/INGREDIENTS.md declares no \"## Declared state\"" >&2
  echo "    add the section -- see scripts/declared-state.sh for the grammar:" >&2
  echo "        ## Declared state" >&2
  echo "        - upstream: UPSTREAM_VERSION" >&2
  echo "        - <name>: <path>[:<KEY>]" >&2
  exit 2
}

# The bytes of the file a declared entry names, from the working tree or (with --ref) from that
# revision's tree. Everything downstream reads $work/entry, so one source of values serves both and
# the rendering cannot differ between them -- which is the point: the digest of a released state and
# the digest of the current state must be comparable, or the comparison means nothing.
# `git show REV:PATH` resolves PATH from the repo ROOT (no leading ./), which is what a declared path
# already is.
entry_bytes() {   # $1 = declared path, relative to the repo root
  if [ -n "$REF" ]; then
    git -C "$ROOT" show "$REF:$1" > "$work/entry" 2>"$work/git-err" || return 1
  else
    [ -f "$ROOT/$1" ] || return 1
    cat "$ROOT/$1" > "$work/entry" || return 1
  fi
}

while IFS="$(printf '\t')" read -r name spec || [ -n "$name" ]; do
  [ -n "$name" ] || continue
  case "$spec" in
    *:*) file="${spec%%:*}"; key="${spec##*:}" ;;
    *)   file="$spec"; key="" ;;
  esac
  if ! entry_bytes "$file"; then
    if [ -n "$REF" ]; then
      echo "release-state: '$name' is declared from $file, which $REF's tree does not have" >&2
      [ ! -s "$work/git-err" ] || sed 's/^/    /' "$work/git-err" >&2
      echo "    a state that cannot be rendered from that revision must not become a digest for it" >&2
    else
      echo "release-state: '$name' is declared from $file, which does not exist under $ROOT" >&2
      echo "    an unrenderable state must not become a new digest, so this is fatal" >&2
    fi
    exit 2
  fi
  if [ -n "$key" ]; then
    value="$(pin_value "$work/entry" "$key")"
    [ -n "$value" ] || {
      echo "release-state: '$name' is declared as $key in $file, which assigns it nothing" >&2
      exit 2
    }
  else
    value="$(tr -d '[:space:]' < "$work/entry")"
    [ -n "$value" ] || { echo "release-state: '$name' is declared from $file, which is empty" >&2; exit 2; }
  fi
  printf '%s=%s\n' "$name" "$value" >> "$lines"
done < "$decl"

# LC_ALL=C so the order is byte order on every box, forever. This line IS the wire format.
rendered="$(LC_ALL=C sort < "$lines")"

if [ "$RENDER" = yes ]; then printf '%s\n' "$rendered"; exit 0; fi
printf 'v1:sha256:%s\n' "$(printf '%s\n' "$rendered" | shasum -a 256 | cut -d' ' -f1)"
