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

# A self-upstream product's own tag shape, derived from the tag being published rather than
# configured per repo: the family has exactly two shapes, and a repo that grows a third gets no
# baseline (today's behaviour) instead of a wrong one.
#
# The v-shaped glob is 'v*.*.*', not 'v[0-9]*': shipyard's own release.yml already uses this spelling
# (--tag-glob 'v*.*.*') for the same reason. Requiring three components excludes the moving major tag
# (v1) from the tag list before it is ever compared -- v1 has no dot, so it cannot match this glob at
# all. That is stronger than relying on ver_cmp to rank it last: with only v1 and v1.0.1 in the repo,
# ver_cmp still puts v1 last, but the max of what remains is still v1 once v1.0.1 is excluded (the tag
# being published), and a first v2.0.0 published against a bare "v2" alias has the same shape.
SELF_GLOB=""
if [ "$SELF_UPSTREAM" = yes ]; then
  case "$TAG" in
    v[0-9]*) SELF_GLOB='v*.*.*' ;;
    [0-9]*)  SELF_GLOB='[0-9]*' ;;
  esac
fi

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

# An EMPTY result is legitimate (a genuine first release has no baseline); a NON-ZERO exit is not --
# that is previous-release-tag.sh itself failing (e.g. an unreadable tag list), and swallowing it here
# is exactly the "shorter body, green run" shape this generator exists to stop: no baseline means no
# ingredient section and no compare link, silently, for a release that may well have both.
if [ -n "$SELF_GLOB" ]; then
  PREV="$(sh "$SELF/previous-release-tag.sh" --tag-glob "$SELF_GLOB" "$TAG")" && prevrc=0 || prevrc=$?
else
  PREV="$(sh "$SELF/previous-release-tag.sh" "$TAG" ${LINE:+"$LINE"})" && prevrc=0 || prevrc=$?
fi
[ "$prevrc" -eq 0 ] \
  || die "previous-release-tag.sh failed (exit $prevrc) for $TAG; cannot decide the compare baseline or whether an ingredient moved without it"

# An unmatched --line is indistinguishable from "no earlier release" at this point, and the result is
# a repackage published with no ingredient section and no compare link, green. The tags carry the
# upstream's own dotted prefix (1.26.7-mavericks.N), so the glob must be "1.26" -- "126" is the shape
# a human reaches for and it matches nothing. N=1 is left alone: the first release of a new line
# genuinely has no baseline.
if [ -n "$LINE" ] && [ -z "$PREV" ] && [ "$SELF_UPSTREAM" = no ]; then
  case "${VER##*-mavericks.}" in
    1) ;;
    *) die "--line matches no ${LINE}-mavericks.* tag, so $VER (a repackage) would ship with no compare link and no ingredient section; pass the prefix the tags actually carry (1.26, not 126)" ;;
  esac
fi

tmp="$(mktemp "${TMPDIR:-/tmp}/release-notes.XXXXXX")"
footer_tmp="$(mktemp "${TMPDIR:-/tmp}/release-notes-footer.XXXXXX")"
trap 'rm -f "$tmp" "$footer_tmp"' EXIT

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
# something else falls through to discovery at all.
#
# The convention-named path is still only a NAME, though: a scaffolded or disabled placeholder can
# sit there without ever calling the reusable workflow, and existence alone is not evidence it does.
# The same content test that gates discovery gates the default path too, so a half-wired placeholder
# there falls through to discovery (finding a real caller under another name) or to no caller at all
# -- never to a false claim that this repo is wired up when it is not.
#
# The test is "names the reusable workflow on a line that is not a comment", NOT "has a line matching
# `uses:.*<filename>`". `uses: >-` with the URI on the continuation line is valid YAML and a genuine
# call, but puts the word `uses:` and the filename on DIFFERENT lines; anchoring on `uses:` read that
# wired-up repo as having no caller and shipped "packaging changes only" over a real libressl bump, at
# exit 0 -- the original openssh bug reintroduced for nothing but a formatting choice. Excluding
# comment lines (optional whitespace then `#`) is what still keeps the decoy's "# Dispatched by ..."
# from counting as a call, and the placeholder, which names the workflow nowhere, out either way.
# Residual: a non-comment line that names the file without calling it (`run: echo "... .yml"`) now
# reads as a caller. That only matters in a repo with no real caller, and is rarer than the folded
# scalar; a silent drop on a genuinely-wired repo is the worse of the two.
#
# And when discovery -- only ever reached by a repo whose caller is NOT at the conventional path --
# finds more than one candidate, it does not guess. Taking the first in glob order let an
# earlier-sorting decoy (`- run: echo "dispatched by repackage-on-ingredient-bump.yml"`) outrank the
# real caller and report its OWN paths as the ingredients that moved: confidently wrong notes, which
# is the worse of the two failure shapes. Ranking candidates cannot separate them (a decoy yields
# pins too, and a folded-scalar caller is the weaker textual match by construction), so which workflow
# defines the ingredient set is simply ambiguous, and an ambiguous ingredient set is a gap. Gaps stop
# the release loudly here. One candidate is unambiguous and behaves exactly as before; the
# conventional path still short-circuits discovery entirely, so no family repo reaches this at all.
CALLER=""
default_caller="$MAVERICKS_ROOT/.github/workflows/repackage-on-ingredient-bump.yml"
is_caller() {
  grep -v '^[[:space:]]*#' "$1" 2>/dev/null | grep -Fq 'repackage-on-ingredient-bump.yml'
}
if [ -f "$default_caller" ] && is_caller "$default_caller"; then
  CALLER="$default_caller"
else
  ncand=0; candidates=""
  for f in "$MAVERICKS_ROOT"/.github/workflows/*.yml "$MAVERICKS_ROOT"/.github/workflows/*.yaml; do
    [ -f "$f" ] || continue
    is_caller "$f" || continue
    ncand=$((ncand + 1)); CALLER="$f"
    candidates="${candidates:+$candidates, }$f"
  done
  [ "$ncand" -le 1 ] \
    || die "more than one workflow names repackage-on-ingredient-bump.yml and none of them is at the conventional path .github/workflows/repackage-on-ingredient-bump.yml, so which one defines this repo's ingredient pins is ambiguous: $candidates (rename the real caller to the conventional path, or drop the mention from the other)"
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
  URL="$(sh "$SELF/upstream-notes.sh" --url-only "$VER")"; urc=$?
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
# Buffered separately so the '---' rule above it is emitted ONLY when at least one footer line
# follows: swift-toolchain has neither a --min-os floor nor (in a fixture with no remote) a compare link, and
# a body ending in a dangling <hr> with nothing after it is not a sentence either.
[ -z "$MINOS" ] || printf 'Requires Mac OS X %s or later.\n' "$MINOS" >> "$footer_tmp"

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
  [ -z "$REPO_URL" ] || printf '[All changes since %s](%s/compare/%s...%s)\n' "$PREV" "$REPO_URL" "$PREV" "$TAG" >> "$footer_tmp"
fi

if [ -s "$footer_tmp" ]; then
  printf '\n---\n' >> "$tmp"
  cat "$footer_tmp" >> "$tmp"
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
