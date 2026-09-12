#!/bin/sh
# Generate ONE product's release notes: the Sparkle appcast <description> and the GitHub Release body,
# which are the same bytes by construction.
#
#   usage: release-notes.sh --tag T --version V --product P --out FILE [--line L] [--min-os M]
#     --tag/--version   the release tag and full version (equal for most repos; golang's differ)
#     --product         the BARE product noun ("OpenSSH", "Go", "Signal Desktop"). This composes the
#                       family's prose register: "OpenSSH 9.9p2 for Mavericks (9.9p2-mavericks.6)".
#     --line            upstream-line prefix for a repo shipping parallel lines (golang: "1.26";
#                       "1.26.*" also accepted -- both are normalized to a glob before use)
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

# --line is documented human-friendly ("1.26"), but previous-release-tag.sh takes a GLOB it appends
# "-mavericks.*" to; passing the bare prefix silently matches nothing (1.26 vs the real tag
# 1.26.7-mavericks.N), which is how a real golang repackage was reported as "First release" with no
# compare link. Normalize here so both "1.26" and "1.26.*" work; leave empty (no --line) alone.
if [ -n "$LINE" ]; then
  case "$LINE" in
    *'*') ;;                      # already a glob
    *) LINE="$LINE.*" ;;
  esac
fi

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

# A non-shallow checkout can still hide tags (git clone --no-tags, actions/checkout fetch-tags:
# false): git tag --list succeeds and is simply empty, so the shallow guard above never fires. Without
# this check that reads as "no earlier release of $UP", and a repackage (-mavericks.N, N>1) is
# announced as a brand-new upstream with a spurious link and no ingredient section -- the same
# silent-drop shape the shallow guard exists to stop, through a different door. N=1 with no visible
# tags is left alone: that IS what a genuine first release, or a dispatch-cut build whose own tag does
# not exist yet, looks like.
if [ "$SELF_UPSTREAM" = no ]; then
  UPTAGS="$(git tag --list "$UP-mavericks.*" 2>/dev/null || true)"
  if [ -z "$UPTAGS" ]; then
    N="${VER##*-mavericks.}"
    case "$N" in
      1) ;;
      *) die "$VER is -mavericks.$N but no $UP-mavericks.* tags are visible in $MAVERICKS_ROOT, so it is unknown whether this is a first release or a repackage (tags may not be fetched -- use fetch-tags: true or fetch-depth: 0)" ;;
    esac
  fi
fi

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
#
# The caller is discovered by what it CALLS, not by its own filename: ingredient-pins.sh's default
# path is only a convention, and a caller under any other name silently read as "no ingredients" --
# which is the exact original openssh bug (a real libressl bump reported as "packaging changes only")
# reproduced through this script. And `|| true` on a crash in ingredient-pins.sh reads the same way:
# "this repo has no ingredients" instead of "the pins could not be read". Neither is a repackage that
# is allowed to ship: a repo wired to repackage on ingredient bumps whose notes cannot say which
# ingredient moved is precisely the gap this plan closes.
#
# Discovery is a FALLBACK, not a search: the convention-named file wins outright when it exists, so a
# workflow that merely MENTIONS the caller (a comment documenting a dispatch trigger, e.g.
# "# Dispatched by repackage-on-ingredient-bump.yml ...") can never outrank the real caller sitting
# right next to it, however the two sort in a directory listing. Only a repo whose caller is named
# something else falls through to discovery at all, and there the match requires an actual `uses:`
# line -- a mention alone is not a call.
default_caller="$MAVERICKS_ROOT/.github/workflows/repackage-on-ingredient-bump.yml"
if [ -f "$default_caller" ]; then
  CALLER="$default_caller"
else
  CALLER=""
  for f in "$MAVERICKS_ROOT"/.github/workflows/*.yml "$MAVERICKS_ROOT"/.github/workflows/*.yaml; do
    [ -f "$f" ] || continue
    grep -Eq 'uses:.*repackage-on-ingredient-bump\.yml' "$f" 2>/dev/null && { CALLER="$f"; break; }
  done
fi
PINS=""
if [ -n "$CALLER" ]; then
  PINS="$(sh "$SELF/ingredient-pins.sh" "$CALLER")" \
    || die "ingredient-pins.sh failed reading the pins $CALLER watches; a repackage caller whose pins cannot be read must not ship notes that call it packaging-only"
  [ -n "$PINS" ] || die "$CALLER calls repackage-on-ingredient-bump.yml but ingredient-pins.sh found no pins in it (check its 'paths:' list and own-upstream-paths)"
fi
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
# release has no baseline, and a checkout with no remote (a test fixture) has no URL to build. This is
# the Sparkle <description> a 10.9 user reads in the update dialog -- a bare "since X...Y" with no
# link is not a sentence and gives them nothing to act on, so when no repository URL can be derived
# the line is omitted entirely rather than shown as unusable text.
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
  [ -z "$REPO_URL" ] || printf '[All changes since %s](%s/compare/%s...%s)\n' "$PREV" "$REPO_URL" "$PREV" "$TAG" >> "$tmp"
fi

# --- self-check: never hand back something the publisher would refuse -----------------------------
if ! sh "$SELF/check-release-notes.sh" "$tmp" "$VER" >/dev/null; then
  if [ -f "$notes" ] && [ -s "$notes" ]; then
    die "the generated body failed the family shape check (see the complaint above); likely cause: the committed prose at $notes"
  else
    die "the generated body failed the family shape check (see the complaint above); this is a bug in release-notes.sh"
  fi
fi

mkdir -p "$(dirname "$OUT")"
cat "$tmp" > "$OUT"
echo "release-notes: wrote $OUT for $VER"
