#!/bin/sh
# Describe which build-ingredient pins moved since the previous release, as a markdown section for
# the release notes (Sparkle appcast <description> + GitHub Release body).
#
# Prints NOTHING when no pin moved, when there is no previous release, or when no pins were passed --
# so callers can append its output unconditionally. Never fails a release: a missing pin path is
# skipped with a warning, and call sites should still use `|| true`.
#   usage: ingredient-notes.sh <prev-tag> [pin-path...]
#
# Shapes, because a pin is not always a bare version string:
#   single-line file  ->  old -> new                      (components/<name>/version)
#   *.sh assignments  ->  one bullet per changed KEY       (versions.sh: MLS_VERSION, CA_SHA256)
#   anything else     ->  "updated (N -> M bytes)"        (vendor/cacert.pem and other blobs)
set -eu

prev="${1:-}"
[ -n "$prev" ] || exit 0
shift
[ "$#" -gt 0 ] || exit 0

tmp="$(mktemp -d "${TMPDIR:-/tmp}/ingredient-notes.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
bullets="$tmp/bullets"
: > "$bullets"

# components/golang/version -> "golang"; a patch -> its filename; anything else keeps its path.
pin_name() {
  case "$1" in
    components/*/version) p="${1#components/}"; printf '%s' "${p%/version}" ;;
    *.patch) printf '%s' "${1##*/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# The Subject: line of a mail-formatted patch, minus any [PATCH n/m] prefix. Empty for a plain diff.
patch_subject() {
  sed -n 's/^Subject:[[:space:]]*//p' | sed 's/^\[PATCH[^]]*\][[:space:]]*//' | head -1
}

# A 64-character diff of two hashes tells a reader nothing; 12 characters identifies which is which.
shorten() {
  v="$1"
  case "$v" in
    *[!0-9a-fA-F]*) printf '%s' "$v"; return ;;
  esac
  if [ "${#v}" -ge 32 ]; then printf '%.12s...' "$v"; else printf '%s' "$v"; fi
}

bullet() {  # name old new
  printf -- '- **%s**: %s -> %s\n' "$1" "$(shorten "$2")" "$(shorten "$3")" >> "$bullets"
}

# KEY<TAB>VALUE for each simple assignment, stripped of `export `, quotes, and trailing comment.
#
# LITERALS ONLY. A pinned-inputs file also holds derivations (GO_VERSION="$(upstream_version)",
# PKG_VERSION=`cat VERSION`), and rewriting one of those is a code change, not an ingredient change --
# reporting it would be noise at best and a false claim at worst. A pin is a literal value, so any
# value carrying a substitution ($, backtick) is dropped.
assignments() {
  sed -n 's/^[[:space:]]*export[[:space:]]\{1,\}//; s/^\([A-Za-z_][A-Za-z0-9_]*\)=\(.*\)$/\1	\2/p' \
    | sed 's/[[:space:]]*#.*$//; s/["'"'"']//g; s/[[:space:]]*$//' \
    | grep -v '[$`]' || true
}

for path in "$@"; do
  if [ ! -f "$path" ]; then
    echo "ingredient-notes: skipping missing pin $path" >&2
    continue
  fi
  newsize="$(wc -c < "$path" | tr -d ' ')"

  # Absent at the previous release: a newly introduced pin.
  if ! oldsize="$(git cat-file -s "$prev:$path" 2>/dev/null)"; then
    case "$path" in
      *.patch)
        sub="$(patch_subject < "$path")"
        if [ -n "$sub" ]; then
          printf -- '- **%s**: added ("%s")\n' "$(pin_name "$path")" "$sub" >> "$bullets"
        else
          printf -- '- **%s**: added\n' "$(pin_name "$path")" >> "$bullets"
        fi
        ;;
      *)
        if [ "$newsize" -lt 256 ]; then
          printf -- '- **%s**: added (%s)\n' "$(pin_name "$path")" "$(head -1 "$path")" >> "$bullets"
        else
          printf -- '- **%s**: added\n' "$(pin_name "$path")" >> "$bullets"
        fi
        ;;
    esac
    continue
  fi

  # Binary-safe equality: compare blob hashes rather than slurping contents.
  [ "$(git rev-parse "$prev:$path")" = "$(git hash-object "$path")" ] && continue

  case "$path" in
    *.sh)
      git show "$prev:$path" | assignments | sort > "$tmp/old"
      assignments < "$path" | sort > "$tmp/new"
      while IFS= read -r line; do
        key="${line%%	*}"; newv="${line#*	}"
        oldv="$(grep "^$key	" "$tmp/old" | head -1 | cut -f2- || true)"
        if [ -z "$oldv" ]; then
          printf -- '- **%s**: added (%s)\n' "$key" "$newv" >> "$bullets"
        elif [ "$oldv" != "$newv" ]; then
          bullet "$key" "$oldv" "$newv"
        fi
      done < "$tmp/new"
      # A key that stopped being pinned is a real change to what this product is built from, and
      # walking only the new file would omit it entirely.
      while IFS= read -r line; do
        key="${line%%	*}"
        grep -q "^$key	" "$tmp/new" \
          || printf -- '- **%s**: removed\n' "$key" >> "$bullets"
      done < "$tmp/old"
      ;;
    *.patch)
      # A patch is an ingredient too -- it is baked into the product -- but a byte delta says nothing
      # about one. Report what a reader can act on: what the patch claims to do, and how much moved.
      git show "$prev:$path" > "$tmp/oldpatch"
      oldsub="$(patch_subject < "$tmp/oldpatch")"
      newsub="$(patch_subject < "$path")"
      a="$(diff "$tmp/oldpatch" "$path" | grep -c '^>' || true)"
      d="$(diff "$tmp/oldpatch" "$path" | grep -c '^<' || true)"
      if [ -n "$oldsub" ] && [ -n "$newsub" ] && [ "$oldsub" != "$newsub" ]; then
        printf -- '- **%s**: "%s" -> "%s" (+%s/-%s lines)\n' \
          "$(pin_name "$path")" "$oldsub" "$newsub" "$a" "$d" >> "$bullets"
      elif [ -n "$newsub" ]; then
        printf -- '- **%s**: updated ("%s", +%s/-%s lines)\n' \
          "$(pin_name "$path")" "$newsub" "$a" "$d" >> "$bullets"
      else
        printf -- '- **%s**: updated (+%s/-%s lines)\n' "$(pin_name "$path")" "$a" "$d" >> "$bullets"
      fi
      ;;
    *)
      oldlines="$(git show "$prev:$path" | wc -l | tr -d ' ')"
      newlines="$(wc -l < "$path" | tr -d ' ')"
      if [ "$newsize" -lt 256 ] && [ "$oldlines" -le 1 ] && [ "$newlines" -le 1 ]; then
        bullet "$(pin_name "$path")" "$(git show "$prev:$path" | head -1)" "$(head -1 "$path")"
      else
        printf -- '- **%s**: updated (%s -> %s bytes)\n' "$path" "$oldsize" "$newsize" >> "$bullets"
      fi
      ;;
  esac
done

if [ -s "$bullets" ]; then
  printf '### Build ingredients\n\nChanged since %s:\n\n' "$prev"
  cat "$bullets"
fi
