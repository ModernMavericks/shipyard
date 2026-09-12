#!/bin/sh
# Render this product's declared state canonically, and hash it.
#
# A release is the realisation of a declared state, not the side effect of an event (spec
# 2026-09-12). publish-release.yml records this digest in the release body; release-needed.sh looks
# it up. Two things to know before editing anything here:
#
#   1. The rendering is a WIRE FORMAT. Every published release carries a digest computed from it, so
#      changing the rendering makes every one of them stop matching -- which reads as "nothing has
#      ever been released". Hence the v1: prefix and the golden test. A format bump means RECOMPUTE
#      (release-needed.sh's version-equality fallback), never republish.
#   2. Declared state EXCLUDES the source tree. That is what makes "a push causes feedback and almost
#      never a release" a property of the design rather than a rule someone must enforce.
#
# What is declared lives in INGREDIENTS.md's "## Declared state" section; declared-state.sh is the
# parser and documents the grammar.
#   usage: release-state.sh [--root DIR] [--render]
#          --render  print the canonical rendering instead of its digest (debugging, and the test)
set -eu
SELF="$(cd "$(dirname "$0")" && pwd)"

ROOT="."; RENDER=no
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2%/}"; shift 2;;
    --render) RENDER=yes; shift;;
    *) echo "release-state: unknown option $1" >&2; exit 2;;
  esac
done

# The value assigned to KEY in FILE, quotes stripped, first match wins -- the same shape
# repackage-decision.sh reads, so a pin file means one thing to every script in the family.
pin_value() {  # $1 = file  $2 = key
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1 | sed 's/^"//; s/"$//'
}

_tmp="${TMPDIR:-/tmp}"
work="$(mktemp -d "${_tmp%/}/release-state.XXXXXX")"; trap 'rm -rf "$work"' EXIT
decl="$work/decl"; lines="$work/lines"
: > "$lines"

# A parse failure must not become a digest, so take the parser's exit status before using its output.
sh "$SELF/declared-state.sh" "$ROOT" > "$decl"
[ -s "$decl" ] || {
  echo "release-state: $ROOT/INGREDIENTS.md declares no \"## Declared state\"" >&2
  echo "    add the section -- see scripts/declared-state.sh for the grammar:" >&2
  echo "        ## Declared state" >&2
  echo "        - upstream: UPSTREAM_VERSION" >&2
  echo "        - <name>: <path>[:<KEY>]" >&2
  exit 2
}

while IFS="$(printf '\t')" read -r name spec || [ -n "$name" ]; do
  [ -n "$name" ] || continue
  case "$spec" in
    *:*) file="${spec%%:*}"; key="${spec##*:}" ;;
    *)   file="$spec"; key="" ;;
  esac
  [ -f "$ROOT/$file" ] || {
    echo "release-state: '$name' is declared from $file, which does not exist under $ROOT" >&2
    echo "    an unrenderable state must not become a new digest, so this is fatal" >&2
    exit 2
  }
  if [ -n "$key" ]; then
    value="$(pin_value "$ROOT/$file" "$key")"
    [ -n "$value" ] || {
      echo "release-state: '$name' is declared as $key in $file, which assigns it nothing" >&2
      exit 2
    }
  else
    value="$(tr -d '[:space:]' < "$ROOT/$file")"
    [ -n "$value" ] || { echo "release-state: '$name' is declared from $file, which is empty" >&2; exit 2; }
  fi
  printf '%s=%s\n' "$name" "$value" >> "$lines"
done < "$decl"

# LC_ALL=C so the order is byte order on every box, forever. This line IS the wire format.
rendered="$(LC_ALL=C sort < "$lines")"

if [ "$RENDER" = yes ]; then printf '%s\n' "$rendered"; exit 0; fi
printf 'v1:sha256:%s\n' "$(printf '%s\n' "$rendered" | shasum -a 256 | cut -d' ' -f1)"
