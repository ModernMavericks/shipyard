#!/bin/sh
# Emit the fact stream check-artifact-conformance.sh consumes, by inspecting a built dist/ directory
# and the repo it came from. Deliberately thin: all judgement lives in the checker, so this can be read
# in one sitting and the interesting logic stays testable without fabricating .pkg files.
#
#   usage: artifact-facts.sh <dist-dir> <version> [repo-root]
#
# Runs at PACKAGE TIME, on macOS, where pkgutil exists and the artifacts do -- not in the conventions
# gate, which reads a repo in seconds and gates every PR.
set -eu
dist="${1:?artifact-facts: dist directory required}"
version="${2:?artifact-facts: version required}"
root="${3:-$(pwd)}"

printf 'expected %s\n' "$version"

# A repo shipping parallel upstream lines names the line in every identity. The line is the NAME of the
# lines/<X>/ directory whose UPSTREAM_VERSION matches this build's upstream -- the authoritative source,
# not a guess from the version. That guess only worked for MINOR-based lines (golang: 1.26 -> 126); a
# MAJOR-based line (clang 22, nodejs 24) collapses 22.1.1 -> "221" and no identifier carries it. Reading
# the directory handles both, since versions.sh already refuses a line whose upstream disagrees. Fall
# back to the old major.minor heuristic only if nothing matches (a committed VERSION that has drifted).
if [ -d "$root/lines" ]; then
  _up="${version%%-mavericks.*}"; _line=""
  for _d in "$root"/lines/*/; do
    [ -f "$_d/UPSTREAM_VERSION" ] || continue
    [ "$(tr -d '[:space:]' < "$_d/UPSTREAM_VERSION")" = "$_up" ] && { _line="$(basename "$_d")"; break; }
  done
  [ -n "$_line" ] || _line="$(printf '%s' "$_up" | cut -d. -f1,2 | tr -d '.')"
  printf 'line %s\n' "$_line"
fi

# Declared deviations live in INGREDIENTS.md, under "## Conformance deviations", as
#   - <check>: <reason>
# A deviation IS a product fact, which is why it belongs with the other product facts rather than in a
# file of its own that could disagree with them.
if [ -f "$root/INGREDIENTS.md" ]; then
  sed -n '/^## Conformance deviations/,/^## /p' "$root/INGREDIENTS.md" \
    | sed -n 's/^- *\([a-z][a-z0-9_-]*\)\(:[^ :]*\)\{0,1\} *: *\(..*\)$/deviation \1\2 \3/p'
fi

for f in "$dist"/*; do
  [ -f "$f" ] || continue
  b="${f##*/}"
  printf 'asset %s %s\n' "$b" "$(wc -c < "$f" | tr -d ' ')"

  case "$b" in
    *.pkg)
      # pkgutil is the only way to read what the .pkg actually declares; a filename is a claim, not a
      # fact, and the whole point here is to compare claims against what shipped.
      x="$(mktemp -d "${TMPDIR:-/tmp}/artifact-facts.XXXXXX")"   # template: 10.9 BSD mktemp requires one
      if pkgutil --expand "$f" "$x/x" >/dev/null 2>&1; then
        if [ -f "$x/x/Distribution" ]; then
          # A product archive: version, floor and identity all live in Distribution.
          ver="$(sed -n 's/.*<pkg-ref[^>]*version="\([^"]*\)".*/\1/p' "$x/x/Distribution" | head -1)"
          floor="$(sed -n 's/.*<os-version[^>]*min="\([^"]*\)".*/\1/p' "$x/x/Distribution" | head -1)"
          ident="$(sed -n 's/.*<pkg-ref[^>]*id="\([^"]*\)".*/\1/p' "$x/x/Distribution" | head -1)"
        else
          # A component package: PackageInfo carries version and identity, and there is NO floor to
          # read -- that is structural, not a defect. The checker requires an appcast to declare the
          # minimum instead.
          # Anchor on a SPACE before the attribute name: `[^>]*version="` also matches
          # generator-version="InstallCmds-864.1 (25E246)", whose value contains a space and so shifts
          # every field of the record after it -- corrupting the floor and identifier as well.
          # Restrict to the <pkg-info> element AND anchor on a space before the attribute. Without the
          # element restriction, line 1's <?xml version="1.0"?> matches first; without the space
          # anchor, generator-version="InstallCmds-864.1 (25E246)" matches and its embedded space
          # shifts every later field. Both bugs read as artifact defects rather than parser defects.
          ver="$(sed -n '/<pkg-info/ s/.*[[:space:]]version="\([^"]*\)".*/\1/p' "$x/x/PackageInfo" 2>/dev/null | head -1)"
          ident="$(sed -n '/<pkg-info/ s/.*[[:space:]]identifier="\([^"]*\)".*/\1/p' "$x/x/PackageInfo" 2>/dev/null | head -1)"
          floor=""
        fi
        # The fact stream is whitespace-delimited, so a value containing a space would silently shift
        # the fields after it. Collapse any to underscores: a mangled-looking value is a visible
        # symptom, where a shifted record is an invisible one that fails the WRONG check.
        printf 'pkg %s %s %s %s\n' "$b" \
          "$(printf '%s' "${ver:-unknown}" | tr -s '[:space:]' '_')" \
          "$(printf '%s' "${floor:-none}" | tr -s '[:space:]' '_')" \
          "$(printf '%s' "${ident:-none}" | tr -s '[:space:]' '_')"
      else
        printf 'pkg %s unreadable none none\n' "$b"
      fi
      rm -rf "$x"
      ;;
    RELEASE_NOTES.md)
      # The digest of the RENDERED body, not the markdown: what the appcast carries is the HTML
      # fragment, and comparing markdown to HTML would need a second renderer that could disagree
      # with the real one. gen_appcast.sh --render-notes IS the real one (that is what the seam is
      # for), so the two sides of this comparison cannot drift apart the way two parsers would.
      #
      # Captured, not piped straight into shasum: a pipeline's exit status is its LAST command's, so
      # `render-notes | shasum` would let a renderer failure (gen_appcast.sh refuses empty notes, for
      # instance) print nothing on stdout, run under set -eu without tripping it, and silently digest
      # to sha256-of-empty -- one of two ways this comparison could pass by both sides being broken
      # the same way. Check success and non-emptiness explicitly before digesting.
      render="$(sh "$(dirname "$0")/gen_appcast.sh" --render-notes "$f")" \
        || { echo "artifact-facts: gen_appcast.sh --render-notes failed for $b" >&2; exit 1; }
      [ -n "$render" ] \
        || { echo "artifact-facts: gen_appcast.sh --render-notes produced no output for $b" >&2; exit 1; }
      printf 'notes-render %s %s\n' "$b" "$(printf '%s\n' "$render" | shasum -a 256 | cut -d' ' -f1)"
      ;;
    build-info*)
      # What this variant was built FROM (see build-info.sh). One fact per key so the checker can
      # compare a single key across variants without parsing files itself.
      sed -n 's/^\([a-z][a-z0-9_]*\)=\(..*\)$/\1 \2/p' "$f" \
        | while read -r k v; do printf 'build-info %s %s %s\n' "$b" "$k" "$v"; done
      ;;
    *appcast*.xml)
      # The version that IDENTIFIES the release (and must match the .pkg, tag and floor) is the human
      # shortVersionString. <sparkle:version> is a separate NUMERIC comparison key (X.Y.Z.N) that Sparkle
      # can actually order -- deliberately NOT equal to the "-mavericks.N" release version (see
      # MavericksSparkle.cmake / gen_appcast.sh), so conformance reads shortVersionString here.
      # These, and the minimum system version, are ELEMENTS; the enclosure attributes carry only URL/length/sig.
      ver="$(sed -n 's|.*<sparkle:shortVersionString>\([^<]*\)<.*|\1|p' "$f" | head -1)"
      minos="$(sed -n 's|.*<sparkle:minimumSystemVersion>\([^<]*\)<.*|\1|p' "$f" | head -1)"
      url="$(sed -n 's/.*<enclosure[^>]*url="\([^"]*\)".*/\1/p' "$f" | head -1)"
      len="$(sed -n 's/.*<enclosure[^>]*length="\([^"]*\)".*/\1/p' "$f" | head -1)"
      printf 'appcast %s %s %s %s %s\n' "$b" "${ver:-unknown}" "${url##*/}" "${len:-0}" "${minos:-none}"
      # The full URL as its own fact: the basename answers "does this asset exist", the URL answers
      # "does this feed point into THIS release".
      [ -z "$url" ] || printf 'enclosure-url %s %s\n' "$b" "$url"
      # The <description> CDATA, digested. gen_appcast.sh wraps the rendered notes in a leading blank
      # line and an injected <style> block (see its heredoc) that --render-notes never emits; strip
      # both with awk (the content spans lines, so a line-oriented sed can't isolate it) so this
      # compares the NOTES against notes-render, not gen_appcast's own CDATA wrapping. Emitted with no
      # digest when the appcast has no description at all -- the checker treats that as a failure,
      # because the description is what a 10.9 user reads in the update dialog, not something to skip.
      desc="$(awk '
        /<!\[CDATA\[/ { inside = 1; sub(/.*<!\[CDATA\[/, ""); }
        inside {
          if (match($0, /\]\]>/)) { $0 = substr($0, 1, RSTART - 1); inside = 0 }
          if ($0 !~ /^[[:space:]]*$/ && $0 !~ /^<style[ >]/) print
          if (inside == 0) exit
        }' "$f" | shasum -a 256 | cut -d' ' -f1)"
      if awk '/<!\[CDATA\[/ { found = 1 } END { exit !found }' "$f"; then
        printf 'appcast-notes %s %s\n' "$b" "$desc"
      else
        printf 'appcast-notes %s\n' "$b"
      fi
      ;;
  esac
done
