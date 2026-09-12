#!/bin/sh
# Generate ONE product's release notes: the Sparkle appcast <description> and the GitHub Release body,
# which are the same bytes by construction.
#
#   usage: release-notes.sh --tag T --version V --product P --out FILE [--line L] [--min-os M]
#     --tag/--version   the release tag and full version (equal for most repos; golang's differ)
#     --product         the BARE product noun ("OpenSSH", "Go", "Signal Desktop"). This composes the
#                       family's prose register: "OpenSSH 9.9p2 for Mavericks (9.9p2-mavericks.6)".
#     --line            upstream-line prefix for a repo shipping parallel lines (golang: "1.26")
#     --min-os          emits the install floor line; omit for a product that is not a 10.9 .pkg
#
# Sections, in order: title, committed prose (verbatim, never rewritten), What changed, Build
# ingredients (only when a pin moved), footer.
#
# NOTES ARE PART OF THE RELEASE CONTRACT. Every gap here is fatal and names its cause. The old
# doctrine -- prose must never fail a release -- meant every section was appended with `|| true` and
# 2>/dev/null, so a broken hook or an unfindable baseline produced a shorter body and a green run:
# openssh never listed an ingredient in any release, and signal-desktop shipped a new upstream with no
# link. A release that says less than the truth is the defect this removes.
set -eu
SELF="$(cd "$(dirname "$0")" && pwd)"
. "$SELF/lib.sh"          # MAVERICKS_ROOT

TAG=""; VER=""; PRODUCT=""; OUT=""; LINE=""; MINOS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG="$2"; shift 2;;
    --version) VER="$2"; shift 2;;
    --product) PRODUCT="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --line) LINE="$2"; shift 2;;
    --min-os) MINOS="$2"; shift 2;;
    *) echo "release-notes: unknown argument: $1" >&2; exit 2;;
  esac
done
die() { echo "release-notes: $1" >&2; exit 1; }
[ -n "$TAG" ] || die "--tag is required"
[ -n "$VER" ] || die "--version is required"
[ -n "$PRODUCT" ] || die "--product is required (the bare product noun, e.g. OpenSSH)"
[ -n "$OUT" ] || die "--out is required"

cd "$MAVERICKS_ROOT"

# Tags decide the release kind, so a checkout that cannot show them cannot generate notes. This is the
# signal-desktop shape: with fetch-depth 1 every repackage looks like a new upstream, or every new
# upstream loses its link, and nothing goes red.
[ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = false ] \
  || die "$MAVERICKS_ROOT is a shallow clone, so release tags are unknown and the release kind cannot be decided (use fetch-depth: 0)"
git tag --list >/dev/null 2>&1 || die "cannot list release tags in $MAVERICKS_ROOT"

UP="${VER%%-mavericks.*}"
SELF_UPSTREAM=no
if [ "$UP" = "$VER" ]; then SELF_UPSTREAM=yes; fi

PREV="$(sh "$SELF/previous-release-tag.sh" "$TAG" ${LINE:+"$LINE"} || true)"

tmp="$(mktemp "${TMPDIR:-/tmp}/release-notes.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

# --- title ----------------------------------------------------------------------------------------
if [ "$SELF_UPSTREAM" = yes ]; then
  printf '## %s %s\n' "$PRODUCT" "$VER" > "$tmp"
else
  printf '## %s %s for Mavericks (%s)\n' "$PRODUCT" "$UP" "$VER" > "$tmp"
fi

# --- committed prose, verbatim --------------------------------------------------------------------
notes="$MAVERICKS_ROOT/release-notes/${TAG}.md"
if [ -f "$notes" ] && [ -s "$notes" ]; then
  printf '\n' >> "$tmp"; cat "$notes" >> "$tmp"
fi

# --- What changed ---------------------------------------------------------------------------------
printf '\n### What changed\n' >> "$tmp"

# An ingredient section is what distinguishes an ingredient repackage from a packaging-only one, so
# compute it first. ingredient-pins.sh derives the pins from the repo's own repackage caller, which is
# what keeps the release trigger and the notes from drifting apart.
PINS="$(sh "$SELF/ingredient-pins.sh" || true)"
INGREDIENTS=""
if [ -n "$PREV" ] && [ -n "$PINS" ]; then
  # shellcheck disable=SC2086  # PINS is a deliberate list of paths
  INGREDIENTS="$(sh "$SELF/ingredient-notes.sh" "$PREV" $PINS)" \
    || die "cannot read the ingredient pins that moved since $PREV; a repackage that cannot say what moved must not ship"
fi

if [ "$SELF_UPSTREAM" = yes ]; then
  printf -- '- Release of %s %s.\n' "$PRODUCT" "$VER" >> "$tmp"
else
  set +e
  URL="$(sh "$SELF/upstream-notes.sh" --url-only "$VER" 2>/dev/null)"; urc=$?
  set -e
  case "$urc" in
    0)
      if [ -n "$PREV" ]; then
        printf -- '- New upstream: %s %s (was %s).\n' "$PRODUCT" "$UP" "${PREV%%-mavericks.*}" >> "$tmp"
      else
        printf -- '- First release of %s %s for Mavericks.\n' "$PRODUCT" "$UP" >> "$tmp"
      fi
      printf -- '  [Upstream release notes for %s](%s)\n' "$UP" "$URL" >> "$tmp"
      ;;
    3)  # a repackage: no upstream change
      if [ -n "$INGREDIENTS" ]; then
        printf -- '- Repackage of upstream %s %s, rebuilt because build ingredients moved (below).\n  No upstream change.\n' \
          "$PRODUCT" "$UP" >> "$tmp"
      else
        printf -- '- Repackage of upstream %s %s; packaging changes only.\n' "$PRODUCT" "$UP" >> "$tmp"
      fi
      ;;
    4)  # no hook -- allowed ONLY where the repo declares why
      grep -q 'No upstream release notes: *[^ ]' "$MAVERICKS_ROOT/INGREDIENTS.md" 2>/dev/null \
        || die "$VER ships a new upstream but this repo has no build/upstream-release-notes-url.sh, and INGREDIENTS.md does not say why (add the hook, or a line 'No upstream release notes: <reason>')"
      printf -- '- New upstream: %s %s.\n' "$PRODUCT" "$UP" >> "$tmp"
      ;;
    *)  # a hook that failed, or printed something that is not one URL
      die "$VER ships a new upstream but upstream-release-notes-url.sh did not print exactly one URL for $UP (run it by hand to see why)"
      ;;
  esac
fi

# --- Build ingredients ----------------------------------------------------------------------------
[ -z "$INGREDIENTS" ] || printf '\n%s\n' "$INGREDIENTS" >> "$tmp"

# --- footer ---------------------------------------------------------------------------------------
printf '\n---\n' >> "$tmp"
[ -z "$MINOS" ] || printf 'Requires Mac OS X %s or later.\n' "$MINOS" >> "$tmp"

# The compare link is objective "everything else that changed". Its absence is not an error: a first
# release has no baseline, and a checkout with no remote (a test fixture) has no URL to build -- but
# the baseline is still worth naming even without a link, so callers can find it by hand.
if [ -n "$PREV" ]; then
  if [ -n "${GITHUB_SERVER_URL:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
    REPO_URL="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY"
  else
    origin="$(git config --get remote.origin.url 2>/dev/null || true)"
    case "$origin" in
      git@github.com:*) REPO_URL="https://github.com/$(printf '%s' "${origin#git@github.com:}" | sed 's/\.git$//')" ;;
      https://github.com/*) REPO_URL="$(printf '%s' "$origin" | sed 's/\.git$//')" ;;
      *) REPO_URL="" ;;
    esac
  fi
  if [ -n "$REPO_URL" ]; then
    printf '[All changes since %s](%s/compare/%s...%s)\n' "$PREV" "$REPO_URL" "$PREV" "$TAG" >> "$tmp"
  else
    printf 'All changes since %s...%s\n' "$PREV" "$TAG" >> "$tmp"
  fi
fi

# --- self-check: never hand back something the publisher would refuse -----------------------------
sh "$SELF/check-release-notes.sh" "$tmp" "$VER" >/dev/null \
  || die "the generated notes are not the family shape (see the complaint above); this is a bug in release-notes.sh"

mkdir -p "$(dirname "$OUT")"
cat "$tmp" > "$OUT"
echo "release-notes: wrote $OUT for $VER"
