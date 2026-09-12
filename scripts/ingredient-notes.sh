#!/bin/sh
# Describe which build-ingredient pins moved since the previous release, as a markdown section for
# the release notes (Sparkle appcast <description> + GitHub Release body).
#
# Prints NOTHING when no pin moved, when there is no previous release, or when no pins were passed --
# so callers can append its output unconditionally. Never fails a release: a missing pin path is
# skipped with a warning, and call sites should still use `|| true`.
#   usage: ingredient-notes.sh <prev-tag> [pin-path[:KEY]...]
#     a "path:KEY" argument (ingredient-pins.sh's own-upstream-paths key form) excludes just that KEY
#     from the file's ingredient set -- the file's other keys are still reported normally.
#
# Shapes, because a pin is not always a bare version string:
#   single-line file    ->  old -> new                    (components/<name>/version)
#   KEY=VALUE assignments -> one bullet per changed KEY    (versions.sh, pins.env: decided by CONTENT,
#                                                            not by extension -- see is_kv_pins())
#   anything else        ->  "updated (N -> M bytes)"      (vendor/cacert.pem and other blobs)
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

# components/*/version files (container-tools' REPO=/REF=/DIGEST=/BASE= shape) are ONE OF SEVERAL
# pin files sharing those same four key names -- unlike versions.sh/pins.env, which are the repo's
# one and only pin file. A bare "REF" bullet is unambiguous only until a SECOND component moves in
# the same release, so these are prefixed with the component name ALWAYS, not just when this run
# happens to be ambiguous (an unprefixed bullet that reads fine today silently becomes misattributed
# the day that second component moves). Every other pin file needs no prefix at all.
label_prefix_for() {
  case "$1" in
    components/*/version) printf '%s / ' "$(pin_name "$1")" ;;
    *) printf '' ;;
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
#
# The key is restricted to UPPERCASE (the family's own naming convention for every real pin:
# SWIFT_VERSION, MLS_VERSION, REPO, REF, DIGEST, BASE, ...), not just "starts with a letter": a
# lowercase-tolerant class also matches base64 PADDING lines in a real blob like vendor/cacert.pem
# ("dZWAUWpLMKawYqGT8ZvYzsRjdT9ZR7E=") as a one-character "assignment", which is exactly the kind of
# blob is_kv_pins() below exists to keep OUT of the per-key branch.
#
# Uppercase-only narrows but does not close that class: an ALL-CAPS-and-digit padding line ("MK9=")
# still matches -- its "value" (everything after the first "=") is empty. Every base64 padding line
# has "=" only at the end, so its value is either empty or made entirely of "="; a real pin's value
# never is. Requiring the value to hold at least one non-"=" character is what actually kills the
# class, rather than thinning it -- the reviewer measured ~0.46 expected such lines per real
# CA-bundle refresh at uppercase-only, i.e. even odds of resurrecting this exact false claim again.
assignments() {
  sed -n 's/^[[:space:]]*export[[:space:]]\{1,\}//; s/^\([A-Z][A-Z0-9_]*\)=\(.*\)$/\1	\2/p' \
    | sed 's/[[:space:]]*#.*$//; s/["'"'"']//g; s/[[:space:]]*$//' \
    | grep -v '[$`]' \
    | awk -F'\t' '$2 ~ /[^=]/' || true
}

# Every KEY the file ASSIGNS, literal or derived. assignments() drops derived values on purpose --
# rewriting a $(...) is a code change, not an ingredient move -- but "not a literal any more" and
# "not in the build any more" are different facts, and the removal walk below could not tell them
# apart. swift-runtime's SWIFT_TAG became "swift-${SWIFT_VERSION}-RELEASE", exactly as the family's
# derive-never-repeat convention requires, and its notes announced the pin as removed.
assigned_keys() {
  sed -n 's/^[[:space:]]*export[[:space:]]\{1,\}//; s/^\([A-Z][A-Z0-9_]*\)=.*$/\1/p'
}

# A pin file gets the per-key rendering when it has at least one shell-style KEY=VALUE (or
# `export KEY=VALUE`) assignment line -- a CONTENT test, not an extension test. pins.env holds the
# exact same shape as pins.sh under a different name (and, like pins.sh, may also source another
# file or run a plain conditional -- assignments() already ignores any line that is not itself an
# assignment, so detecting the shape needs only ONE such line, not uniformity across the whole
# file). A genuine blob (a patch, a vendored binary, a single bare version string) has none and falls
# through to the opaque byte-delta fallback regardless of what it happens to be called.
#
# Defined directly in terms of assignments() -- not a second, hand-synced parse of the same
# question -- so the two can never drift: a file assignments() extracts nothing from can never take
# the per-key branch (which would render zero bullets and silently say NOTHING about a pin that did
# change), and a file it extracts something from always does.
is_kv_pins() {
  [ -n "$(assignments < "$1")" ]
}

for arg in "$@"; do
  # A "path:KEY" argument (ingredient-pins.sh's own-upstream-paths key form) names a file where one
  # KEY is the repo's own upstream, not an ingredient; every OTHER key in the same file still is.
  case "$arg" in
    *:*) path="${arg%%:*}"; exclkey="${arg##*:}" ;;
    *) path="$arg"; exclkey="" ;;
  esac
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
        if is_kv_pins "$path"; then
          # Per-key, same as an existing file's added keys below -- a brand-new pins.env must not
          # print $exclkey's (the repo's own upstream) value verbatim just because the whole FILE is
          # new; every OTHER key in it is still a real, reportable ingredient.
          label_prefix="$(label_prefix_for "$path")"
          assignments < "$path" | sort | while IFS= read -r line; do
            key="${line%%	*}"; newv="${line#*	}"
            [ "$key" = "$exclkey" ] && continue
            printf -- '- **%s%s**: added (%s)\n' "$label_prefix" "$key" "$newv" >> "$bullets"
          done
        elif [ "$newsize" -lt 256 ]; then
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
      if is_kv_pins "$path"; then
        label_prefix="$(label_prefix_for "$path")"
        git show "$prev:$path" | assignments | sort > "$tmp/old"
        assignments < "$path" | sort > "$tmp/new"
        while IFS= read -r line; do
          key="${line%%	*}"; newv="${line#*	}"
          [ "$key" = "$exclkey" ] && continue
          oldv="$(grep "^$key	" "$tmp/old" | head -1 | cut -f2- || true)"
          if [ -z "$oldv" ]; then
            printf -- '- **%s%s**: added (%s)\n' "$label_prefix" "$key" "$newv" >> "$bullets"
          elif [ "$oldv" != "$newv" ]; then
            bullet "${label_prefix}${key}" "$oldv" "$newv"
          fi
        done < "$tmp/new"
        # A key that stopped being pinned is a real change to what this product is built from, and
        # walking only the new file would omit it entirely. But it stopped being pinned only if the
        # file stopped assigning it at all -- a key still assigned, just no longer as a literal, is
        # derived now, which is a different (and much smaller) fact.
        assigned_keys < "$path" | sort -u > "$tmp/newkeys"
        while IFS= read -r line; do
          key="${line%%	*}"; oldv="${line#*	}"
          [ "$key" = "$exclkey" ] && continue
          grep -q "^$key	" "$tmp/new" && continue     # still a literal: already handled above
          if grep -q "^$key\$" "$tmp/newkeys"; then
            printf -- '- **%s%s**: now derived (was %s)\n' \
              "$label_prefix" "$key" "$(shorten "$oldv")" >> "$bullets"
          else
            printf -- '- **%s%s**: removed\n' "$label_prefix" "$key" >> "$bullets"
          fi
        done < "$tmp/old"
      else
        oldlines="$(git show "$prev:$path" | wc -l | tr -d ' ')"
        newlines="$(wc -l < "$path" | tr -d ' ')"
        if [ "$newsize" -lt 256 ] && [ "$oldlines" -le 1 ] && [ "$newlines" -le 1 ]; then
          bullet "$(pin_name "$path")" "$(git show "$prev:$path" | head -1)" "$(head -1 "$path")"
        else
          printf -- '- **%s**: updated (%s -> %s bytes)\n' "$path" "$oldsize" "$newsize" >> "$bullets"
        fi
      fi
      ;;
  esac
done

if [ -s "$bullets" ]; then
  printf '### Build ingredients\n\nChanged since %s:\n\n' "$prev"
  cat "$bullets"
fi
