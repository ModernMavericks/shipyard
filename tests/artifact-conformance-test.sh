#!/bin/sh
# Artifact conformance: an artifact must match ITSELF, its NEIGHBOURS, and its SIBLINGS, unless the
# product declares a deviation with a reason.
#
# The checker consumes a fact stream so it can be tested without fabricating real .pkg files; the
# extraction that produces those facts is exercised for real in CI at package time.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
S="$here/../scripts/check-artifact-conformance.sh"

ok() {  # facts on stdin must pass
  printf '%s\n' "$2" | sh "$S" >/dev/null 2>&1 || { echo "FAIL $1: expected pass"; exit 1; }
}
no() {  # facts on stdin must fail, and name the check
  out="$(printf '%s\n' "$3" | sh "$S" 2>&1)" && { echo "FAIL $1: expected failure"; exit 1; }
  printf '%s\n' "$out" | grep -qi "$2" || { echo "FAIL $1: should mention '$2', got: $out"; exit 1; }
}

GOOD='expected 1.26.5-mavericks.5
pkg golang-1.26.5-native-mavericks.5.pkg 1.26.5-mavericks.5 10.9.5 dev.modernmavericks.golang.go126
appcast appcast.xml 1.26.5-mavericks.5 golang-1.26.5-native-mavericks.5.pkg 4096 10.9.5
asset golang-1.26.5-native-mavericks.5.pkg 4096
asset appcast.xml 700'
ok "a coherent release" "$GOOD"

# --- matches ITSELF -------------------------------------------------------------------------------
no "pkg version disagrees with the tag" "version" 'expected 1.26.5-mavericks.5
pkg p.pkg 1.26.5-mavericks.4 10.9.5 dev.modernmavericks.golang.go126
asset p.pkg 10'

no "appcast version disagrees with the pkg" "version" 'expected 1.26.5-mavericks.5
pkg p.pkg 1.26.5-mavericks.5 10.9.5 dev.modernmavericks.golang.go126
appcast appcast.xml 1.26.5-mavericks.4 p.pkg 10
asset p.pkg 10
asset appcast.xml 700'

no "appcast points at an asset that was not published" "enclosure" 'expected 1.0.0-mavericks.1
pkg p.pkg 1.0.0-mavericks.1 10.9.5 dev.modernmavericks.x
appcast appcast.xml 1.0.0-mavericks.1 ghost.pkg 10
asset p.pkg 10
asset appcast.xml 700'

no "appcast enclosure length disagrees with the real file" "length" 'expected 1.0.0-mavericks.1
pkg p.pkg 1.0.0-mavericks.1 10.9.5 dev.modernmavericks.x
appcast appcast.xml 1.0.0-mavericks.1 p.pkg 999
asset p.pkg 10
asset appcast.xml 700'

no "a .pkg without the 10.9.5 floor" "floor" 'expected 1.0.0-mavericks.1
pkg p.pkg 1.0.0-mavericks.1 10.13 dev.modernmavericks.x
asset p.pkg 10'

no "an identifier outside the family scheme" "identifier" 'expected 1.0.0-mavericks.1
pkg p.pkg 1.0.0-mavericks.1 10.9.5 com.example.thing
asset p.pkg 10'

# --- matches its SIBLINGS -------------------------------------------------------------------------
no "a version outside the family scheme" "scheme" 'expected 1.0.0
pkg p.pkg 1.0.0 10.9.5 dev.modernmavericks.x
asset p.pkg 10'

# --- matches its NEIGHBOURS -----------------------------------------------------------------------
no "two pkgs of one release disagree about the version" "version" 'expected 1.0.0-mavericks.1
pkg native.pkg 1.0.0-mavericks.1 10.9.5 dev.modernmavericks.x
pkg cross.pkg 1.0.0-mavericks.2 10.9.5 dev.modernmavericks.x-cross
asset native.pkg 10
asset cross.pkg 10'

# a product with no updater ships no appcast, and that is fine
ok "a tools product with no updater" 'expected 20221003-mavericks.2
pkg ed25519-20221003-mavericks.2.pkg 20221003-mavericks.2 10.9.5 dev.modernmavericks.ed25519
asset ed25519-20221003-mavericks.2.pkg 10'

# --- FLOORS: a product archive declares one; a COMPONENT package cannot ----------------------------
# A component .pkg (PackageInfo, no Distribution) has no os-version floor by construction -- floors are
# a productbuild concept. Its effective minimum lives in the appcast that ships it. golang's cross
# product is exactly this: it TARGETS 10.9 but RUNS on 11.0+, so demanding 10.9.5 of it would be wrong.
ok "a component pkg whose appcast declares the minimum" 'expected 1.26.5-mavericks.5
pkg golang-cross.pkg 1.26.5-mavericks.5 none dev.modernmavericks.golang.go126-cross
appcast appcast-cross.xml 1.26.5-mavericks.5 golang-cross.pkg 10 11.0
asset golang-cross.pkg 10
asset appcast-cross.xml 700'

no "a pkg with no floor and no appcast to declare one" "floor" 'expected 1.0.0-mavericks.1
pkg orphan.pkg 1.0.0-mavericks.1 none dev.modernmavericks.x
asset orphan.pkg 10'

ok "a product archive that does declare 10.9.5" 'expected 1.0.0-mavericks.1
pkg native.pkg 1.0.0-mavericks.1 10.9.5 dev.modernmavericks.x
asset native.pkg 10'

# --- DEVIATIONS, declared with a reason -----------------------------------------------------------
no "an undeclared floor deviation still fails" "floor" 'expected 1.0.0-mavericks.1
pkg p.pkg 1.0.0-mavericks.1 11.0 dev.modernmavericks.x
asset p.pkg 10'

ok "a declared floor deviation passes" 'expected 1.0.0-mavericks.1
deviation floor the cross toolchain runs on modern macOS and targets 10.9; it is not itself a 10.9 install
pkg p.pkg 1.0.0-mavericks.1 11.0 dev.modernmavericks.x
asset p.pkg 10'

no "a deviation with no reason is not a deviation" "reason" 'expected 1.0.0-mavericks.1
deviation floor
pkg p.pkg 1.0.0-mavericks.1 11.0 dev.modernmavericks.x
asset p.pkg 10'

# a declared deviation is scoped to its own check: it does not excuse an unrelated failure
no "a floor deviation does not excuse a bad identifier" "identifier" 'expected 1.0.0-mavericks.1
deviation floor targets 10.9 rather than running on it
pkg p.pkg 1.0.0-mavericks.1 11.0 com.example.thing
asset p.pkg 10'

# --- SCOPED deviations: a mirrored third-party artifact is not ours to conform ---------------------
# swift-toolchain republishes swift.org's .pkg verbatim so the correspondence with download.swift.org
# stays checkable. Its version, floor and identifier are UPSTREAM's and must stay that way -- but that
# must not excuse the artifacts we do build alongside it.
MIRROR='expected 6.3.3-mavericks.2
deviation version:upstream-swift-*.pkg mirrored verbatim from swift.org; the version is upstream own
deviation floor:upstream-swift-*.pkg same mirror
deviation identifier:upstream-swift-*.pkg same mirror
pkg upstream-swift-6.3.3-RELEASE-osx.pkg 6.3.3.20260625101 10.11 org.swift.633202606251a
asset upstream-swift-6.3.3-RELEASE-osx.pkg 10'
ok "a scoped deviation excuses the mirrored pkg" "$MIRROR"

no "the same scoped deviation does NOT excuse our own artifact" "version" 'expected 6.3.3-mavericks.2
deviation version:upstream-swift-*.pkg mirrored verbatim from swift.org
pkg ours.pkg 6.3.3-mavericks.1 10.9.5 dev.modernmavericks.swift
asset ours.pkg 10'

# --- the appcast must point INTO THIS RELEASE ------------------------------------------------------
# An enclosure URL carries the release tag. If it names another release, Sparkle serves users a
# different build than the one just published -- the feed and the release silently disagree, and every
# other check still passes because both artifacts are individually fine.
ok "an enclosure pointing at this release" 'expected 1.26.5-mavericks.5
pkg p.pkg 1.26.5-mavericks.5 10.9.5 dev.modernmavericks.golang.go126
appcast appcast.xml 1.26.5-mavericks.5 p.pkg 10 10.9.5
enclosure-url appcast.xml https://github.com/ModernMavericks/golang/releases/download/1.26.5-mavericks.5/p.pkg
asset p.pkg 10
asset appcast.xml 700'

no "an enclosure pointing at a DIFFERENT release" "enclosure-url" 'expected 1.26.5-mavericks.5
pkg p.pkg 1.26.5-mavericks.5 10.9.5 dev.modernmavericks.golang.go126
appcast appcast.xml 1.26.5-mavericks.5 p.pkg 10 10.9.5
enclosure-url appcast.xml https://github.com/ModernMavericks/golang/releases/download/1.26.5-mavericks.4/p.pkg
asset p.pkg 10
asset appcast.xml 700'

# --- line-scoped identity -------------------------------------------------------------------------
# Where a repo ships parallel upstream lines, the line IS the product: go126 and go127 must not share
# an identifier, or two products claim one install and the updater cannot tell them apart.
ok "identifiers carrying their line" 'expected 1.26.5-mavericks.5
line 126
pkg native.pkg 1.26.5-mavericks.5 10.9.5 dev.modernmavericks.golang.go126
pkg cross.pkg 1.26.5-mavericks.5 none dev.modernmavericks.golang.go126-cross
appcast appcast-cross.xml 1.26.5-mavericks.5 cross.pkg 10 11.0
asset native.pkg 10
asset cross.pkg 10
asset appcast-cross.xml 700'

no "an identifier missing its line" "line" 'expected 1.26.5-mavericks.5
line 126
pkg native.pkg 1.26.5-mavericks.5 10.9.5 dev.modernmavericks.golang
asset native.pkg 10'

# a repo with no lines is not asked the question
ok "a single-line product" 'expected 1.5.2-mavericks.2
pkg p.pkg 1.5.2-mavericks.2 10.9.5 dev.modernmavericks.legacysupport
asset p.pkg 10'

# --- NEIGHBOURS: variants of one release were built from the same ingredients ----------------------
# The artifacts cannot answer this: golang's native .pkg carries the CA bundle and the shim, its cross
# .pkg legitimately does not (cross-built apps look at the native prefix). "Same shim, same CA" is a
# claim about INPUTS, so each variant records what it used and conformance compares the records.
ok "variants agreeing on their ingredients" 'expected 1.26.5-mavericks.5
build-info build-info-native.txt mls_version 1.5.2-mavericks.2
build-info build-info-native.txt ca_sha256 3ff344e30b9b
build-info build-info-cross.txt mls_version 1.5.2-mavericks.2
build-info build-info-cross.txt ca_sha256 3ff344e30b9b
pkg n.pkg 1.26.5-mavericks.5 10.9.5 dev.modernmavericks.golang.go126
asset n.pkg 10'

no "variants built from DIFFERENT shim pins" "mls_version" 'expected 1.26.5-mavericks.5
build-info build-info-native.txt mls_version 1.5.2-mavericks.2
build-info build-info-cross.txt mls_version 1.5.2-mavericks.1
pkg n.pkg 1.26.5-mavericks.5 10.9.5 dev.modernmavericks.golang.go126
asset n.pkg 10'

no "variants built from different CA bundles" "ca_sha256" 'expected 1.26.5-mavericks.5
build-info build-info-native.txt ca_sha256 3ff344e30b9b
build-info build-info-cross.txt ca_sha256 9a1c72b4aa0f
pkg n.pkg 1.26.5-mavericks.5 10.9.5 dev.modernmavericks.golang.go126
asset n.pkg 10'

# keys that SHOULD differ per variant are not evidence of disagreement
ok "per-variant keys may differ" 'expected 1.26.5-mavericks.5
build-info build-info-native.txt variant native
build-info build-info-native.txt arch x86_64
build-info build-info-native.txt prefix /usr/local/go126
build-info build-info-cross.txt variant cross
build-info build-info-cross.txt arch arm64
build-info build-info-cross.txt prefix /usr/local/go126-cross
pkg n.pkg 1.26.5-mavericks.5 10.9.5 dev.modernmavericks.golang.go126
asset n.pkg 10'

# a single-variant product has nothing to compare against
ok "one variant, nothing to disagree with" 'expected 1.5.2-mavericks.2
build-info build-info.txt mls_version 1.5.2-mavericks.2
pkg p.pkg 1.5.2-mavericks.2 10.9.5 dev.modernmavericks.legacysupport
asset p.pkg 10'

ok "a declared disagreement, with a reason" 'expected 1.26.5-mavericks.5
deviation ingredients the cross variant is deliberately built against the previous shim this once
build-info build-info-native.txt mls_version 1.5.2-mavericks.2
build-info build-info-cross.txt mls_version 1.5.2-mavericks.1
pkg n.pkg 1.26.5-mavericks.5 10.9.5 dev.modernmavericks.golang.go126
asset n.pkg 10'

# "ok" must not be indistinguishable from "compared nothing". A check whose silence means both
# "agreed" and "there was nothing to look at" cannot be trusted the day the records stop shipping.
out="$(printf '%s\n' 'expected 1.0.0-mavericks.1
build-info build-info-a.txt commit abc
build-info build-info-b.txt commit abc
pkg p.pkg 1.0.0-mavericks.1 10.9.5 dev.modernmavericks.x
asset p.pkg 10' | sh "$S")"
printf '%s\n' "$out" | grep -qi 'compared 2' \
  || { echo "FAIL should say how many records it compared; got: $out"; exit 1; }

out="$(printf '%s\n' 'expected 1.0.0-mavericks.1
pkg p.pkg 1.0.0-mavericks.1 10.9.5 dev.modernmavericks.x
asset p.pkg 10' | sh "$S")"
printf '%s\n' "$out" | grep -qi 'no build records' \
  || { echo "FAIL should say when there was nothing to compare; got: $out"; exit 1; }

# --- artifact-facts derives the line from lines/<X>/, not a version heuristic ---------------------
# The line is the directory name (matched by upstream version). A MAJOR-based line (clang 22,
# nodejs 24) must emit its major -- not major.minor collapsed ("221"), which no identifier carries.
# A MINOR-based line (golang 1.26 -> 126) must keep working.
AF="$here/../scripts/artifact-facts.sh"
_afline() {  # <full-version> <line-dir> <upstream-in-dir> -> the emitted `line` fact value
  _r="$(mktemp -d "${TMPDIR:-/tmp}/af.XXXXXX")"
  mkdir -p "$_r/lines/$2" "$_r/dist"; printf '%s\n' "$3" > "$_r/lines/$2/UPSTREAM_VERSION"
  sh "$AF" "$_r/dist" "$1" "$_r" | sed -n 's/^line //p'
  rm -rf "$_r"
}
[ "$(_afline 22.1.1-mavericks.1 22 22.1.1)" = 22 ] \
  || { echo "FAIL: major-line should emit 'line 22', not major.minor '221'"; exit 1; }
[ "$(_afline 1.26.5-mavericks.5 126 1.26.5)" = 126 ] \
  || { echo "FAIL: minor-line (golang) should still emit 'line 126'"; exit 1; }

# --- notes: the appcast <description> and the Release body are the same bytes by construction ------
# Both are built from dist/RELEASE_NOTES.md today, which is exactly why the assertion is cheap and why
# a future change that breaks the coupling should be loud: a 10.9 user reading the update dialog must
# not be told a different story than the Release page.
ok "notes: agreement passes" 'expected 9.9p2-mavericks.6
notes-render RELEASE_NOTES.md aaaa1111
appcast-notes appcast.xml aaaa1111'

no "notes: disagreement fails" "notes" 'expected 9.9p2-mavericks.6
notes-render RELEASE_NOTES.md aaaa1111
appcast-notes appcast.xml bbbb2222'

# An appcast with no notes digest at all is a rendering that produced nothing -- the description is
# what a 10.9 user reads in the update dialog, so an empty one is a defect, not an absence to skip.
no "notes: an appcast with no description fails" "notes" 'expected 9.9p2-mavericks.6
notes-render RELEASE_NOTES.md aaaa1111
appcast-notes appcast.xml'

# A product with no appcast at all (a component-only release) has nothing to disagree with.
ok "notes: no appcast, nothing to compare" 'expected 9.9p2-mavericks.6
notes-render RELEASE_NOTES.md aaaa1111'

# ...and a declared deviation excuses it, with a reason, like every other check.
ok "notes: a declared deviation is honoured" 'expected 9.9p2-mavericks.6
deviation notes the swift.org pkg is republished verbatim with its own notes
notes-render RELEASE_NOTES.md aaaa1111
appcast-notes appcast.xml bbbb2222'

# An appcast-notes fact with NO notes-render to compare against is not quietly skipped: the notes
# file's basename is a per-repo INPUT (release-assets.sh's --notes-file), so a product staging its body
# under a name artifact-facts.sh's RELEASE_NOTES.md case does not recognize must not get a green run
# with this whole layer silently disabled. An appcast that carries a description with nothing to
# compare it against is the same "records stopped shipping" shape as an outright disagreement.
no "notes: an appcast-notes fact with no notes-render is not silently skipped" "notes" 'expected 9.9p2-mavericks.6
appcast-notes appcast.xml aaaa1111'

# --- artifact-facts: the two digests actually agree for a REAL pair --------------------------------
# Not a hand-written fixture: a fixture that does not match what the renderer actually emits would let
# this check pass while proving nothing about the real coupling. Build a real notes file, render a real
# appcast from it with gen_appcast.sh (the same tool a release uses), then ask artifact-facts.sh for
# both digests.
GA="$here/../scripts/gen_appcast.sh"
_nr="$(mktemp -d "${TMPDIR:-/tmp}/af-notes.XXXXXX")"
mkdir -p "$_nr/dist"
cat > "$_nr/dist/RELEASE_NOTES.md" <<'NOTES'
## Summary

Some bug fixes.

- Fixed a thing
- Fixed another thing

**Note:** upgrade recommended.

---

Requires 10.9.5 or later.
NOTES
sh "$GA" "Test Channel" "9.9p2-mavericks.6" "https://example.com/x.pkg" "10.9.5" \
  "$_nr/dist/RELEASE_NOTES.md" 'sparkle:edSignature="x" length="10"' > "$_nr/dist/appcast.xml"
_facts="$(sh "$AF" "$_nr/dist" 9.9p2-mavericks.6 "$_nr")"
_render_digest="$(printf '%s\n' "$_facts" | sed -n 's/^notes-render [^ ]* \(..*\)$/\1/p')"
_appcast_digest="$(printf '%s\n' "$_facts" | sed -n 's/^appcast-notes [^ ]* \(..*\)$/\1/p')"
[ -n "$_render_digest" ] \
  || { echo "FAIL: artifact-facts emitted no notes-render fact for a real notes file"; exit 1; }
[ "$_render_digest" = "$_appcast_digest" ] \
  || { echo "FAIL: notes-render and appcast-notes digests should agree for a real rendered pair; got '$_render_digest' vs '$_appcast_digest'"; exit 1; }

# --- (a) a REAL appcast with its <description> emptied must extract as "no digest" ------------------
# Not a hand-written appcast: start from the real one just built and remove only its CDATA content,
# leaving the <description></description> tags in place. This is the specific shape that distinguishes
# "probe for a CDATA section" from "probe for a <description> tag" (the latter would find the empty
# tags present, compute a digest of nothing, and fail for the wrong reason -- a mismatch -- rather than
# reporting no digest at all). Assert directly on the FACT LINE artifact-facts.sh emits, not just on the
# checker's downstream pass/fail, since both probes lead to failure either way; only the fact itself
# tells them apart.
mkdir -p "$_nr/dist-nodesc"
cp "$_nr/dist/RELEASE_NOTES.md" "$_nr/dist-nodesc/RELEASE_NOTES.md"
awk '
  /<description>/ && /<!\[CDATA\[/ { print "      <description></description>"; skip = 1; next }
  skip && /<\/description>/ { skip = 0; next }
  skip { next }
  { print }
' "$_nr/dist/appcast.xml" > "$_nr/dist-nodesc/appcast.xml"
grep -q '<description></description>' "$_nr/dist-nodesc/appcast.xml" \
  || { echo "FAIL: test setup did not produce an empty <description> fixture"; exit 1; }
_nodesc_facts="$(sh "$AF" "$_nr/dist-nodesc" 9.9p2-mavericks.6 "$_nr")"
_nodesc_line="$(printf '%s\n' "$_nodesc_facts" | grep '^appcast-notes ')"
[ "$_nodesc_line" = "appcast-notes appcast.xml" ] \
  || { echo "FAIL: an emptied <description> should emit 'appcast-notes appcast.xml' with no digest field; got: $_nodesc_line"; exit 1; }
no "notes: a real appcast with an emptied description fails" "notes" "$_nodesc_facts"

# --- (b) a REAL appcast built from genuinely DIFFERENT notes must be detected as a mismatch ----------
# Two real renders, not a hand-typed hash: this pins the digest computation's sensitivity to actual
# content, not just its plumbing.
cat > "$_nr/dist/RELEASE_NOTES_B.md" <<'NOTES'
## Summary

Some bug fixes.

- Fixed a totally different thing

Requires 10.9.5 or later.
NOTES
sh "$GA" "Test Channel" "9.9p2-mavericks.6" "https://example.com/x.pkg" "10.9.5" \
  "$_nr/dist/RELEASE_NOTES_B.md" 'sparkle:edSignature="x" length="10"' > "$_nr/dist/appcast-b.xml"
mkdir -p "$_nr/dist-mismatch"
cp "$_nr/dist/RELEASE_NOTES.md" "$_nr/dist-mismatch/RELEASE_NOTES.md"     # notes-render from A
cp "$_nr/dist/appcast-b.xml" "$_nr/dist-mismatch/appcast.xml"             # appcast rendered from B
_mismatch_facts="$(sh "$AF" "$_nr/dist-mismatch" 9.9p2-mavericks.6 "$_nr")"
_a_digest="$(printf '%s\n' "$_mismatch_facts" | sed -n 's/^notes-render [^ ]* \(..*\)$/\1/p')"
_b_digest="$(printf '%s\n' "$_mismatch_facts" | sed -n 's/^appcast-notes [^ ]* \(..*\)$/\1/p')"
[ "$_a_digest" != "$_b_digest" ] \
  || { echo "FAIL: rendering two genuinely different notes files should not produce equal digests"; exit 1; }
no "notes: a real appcast rendered from DIFFERENT notes is a mismatch" "notes" "$_mismatch_facts"

# --- (M8) the style line is stripped by TAG, not by its literal CSS text -----------------------------
# Change the injected <style>...</style> line's content in a real appcast (same tag, different CSS) and
# confirm the digests still agree. If the extraction ever regresses to matching gen_appcast.sh's
# specific "Helvetica Neue" string instead of the <style ...>...</style> shape, this is what catches it
# -- gen_appcast.sh is free to change that CSS without this check caring.
mkdir -p "$_nr/dist-css"
cp "$_nr/dist/RELEASE_NOTES.md" "$_nr/dist-css/RELEASE_NOTES.md"
sed 's#<style>body{font-family:"Helvetica Neue",Helvetica,Arial,sans-serif;font-size:13px;}</style>#<style>body{color:red}</style>#' \
  "$_nr/dist/appcast.xml" > "$_nr/dist-css/appcast.xml"
grep -q '<style>body{color:red}</style>' "$_nr/dist-css/appcast.xml" \
  || { echo "FAIL: test setup did not change the injected CSS"; exit 1; }
_css_facts="$(sh "$AF" "$_nr/dist-css" 9.9p2-mavericks.6 "$_nr")"
_css_render_digest="$(printf '%s\n' "$_css_facts" | sed -n 's/^notes-render [^ ]* \(..*\)$/\1/p')"
_css_appcast_digest="$(printf '%s\n' "$_css_facts" | sed -n 's/^appcast-notes [^ ]* \(..*\)$/\1/p')"
[ "$_css_render_digest" = "$_css_appcast_digest" ] \
  || { echo "FAIL: changing the injected CSS content should not change the digest (tag-based stripping regressed to a literal string match)"; exit 1; }

rm -rf "$_nr"

# --- (M14) the style-line strip is anchored, so it cannot over-strip real content ---------------------
# esc() HTML-escapes '<' before any of our own tags are injected, so no notes-derived line can ever
# start with a literal "<style" -- but a legitimate content line CAN contain that substring somewhere
# in the MIDDLE (e.g. prose mentioning an inline style). Hand-built, not from the renderer: this probes
# the extraction awk's own precision (the ^ anchor), a property the renderer's escaping makes it
# impossible to exercise through --render-notes itself. Without the anchor, an unanchored /<style/
# would strip this legitimate line too, silently losing real content from the digest.
_m14="$(mktemp -d "${TMPDIR:-/tmp}/af-notes-m14.XXXXXX")"
mkdir -p "$_m14/dist"
# No RELEASE_NOTES.md here: this probes only appcast.xml's extraction, and an empty one would now be
# refused outright by the F4 fix below (correctly) rather than silently ignored.
ASIDE='<p>An aside: <style>tiny</style> shown inline, deliberately not at line start.</p>'
cat > "$_m14/dist/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <item>
      <sparkle:shortVersionString>9.9p2-mavericks.6</sparkle:shortVersionString>
      <description><![CDATA[
<style>body{font-family:"Helvetica Neue",Helvetica,Arial,sans-serif;font-size:13px;}</style>
<p>Ordinary paragraph line one.</p>
$ASIDE
]]></description>
    </item>
  </channel>
</rss>
XML
_m14_facts="$(sh "$AF" "$_m14/dist" 9.9p2-mavericks.6 "$_m14")"
_m14_digest="$(printf '%s\n' "$_m14_facts" | sed -n 's/^appcast-notes [^ ]* \(..*\)$/\1/p')"
_m14_expected="$(printf '%s\n%s\n' '<p>Ordinary paragraph line one.</p>' "$ASIDE" | shasum -a 256 | cut -d' ' -f1)"
rm -rf "$_m14"
[ -n "$_m14_digest" ] \
  || { echo "FAIL: M14 fixture emitted no appcast-notes digest at all"; exit 1; }
[ "$_m14_digest" = "$_m14_expected" ] \
  || { echo "FAIL: the boilerplate <style> line should be stripped but a mid-line '<style' occurrence in real content must survive; got '$_m14_digest', expected '$_m14_expected'"; exit 1; }

# --- a renderer failure must not be swallowed into a quiet sha256-of-empty ---------------------------
# `render-notes | shasum` (a pipeline) would let gen_appcast.sh's own refusal of an empty notes file
# exit non-zero while the pipeline's LAST command (shasum) still exits 0, so set -eu never fires and
# artifact-facts.sh would keep going with a notes-render fact for nothing at all -- one of two ways
# "both sides empty, therefore equal, therefore pass" could happen. artifact-facts.sh itself must fail.
_empty="$(mktemp -d "${TMPDIR:-/tmp}/af-notes-empty.XXXXXX")"
mkdir -p "$_empty/dist"
: > "$_empty/dist/RELEASE_NOTES.md"
_empty_out="$(mktemp "${TMPDIR:-/tmp}/af-notes-empty-out.XXXXXX")"
if sh "$AF" "$_empty/dist" 9.9p2-mavericks.6 "$_empty" >"$_empty_out" 2>&1; then
  rm -rf "$_empty"; rm -f "$_empty_out"
  echo "FAIL: artifact-facts.sh should refuse an empty RELEASE_NOTES.md, not emit a notes-render fact for it"
  exit 1
fi
grep -qi 'render-notes' "$_empty_out" \
  || { echo "FAIL: artifact-facts.sh's failure on an empty notes file should name the renderer; got: $(cat "$_empty_out")"; rm -rf "$_empty"; rm -f "$_empty_out"; exit 1; }
rm -rf "$_empty"; rm -f "$_empty_out"

echo "PASS: artifact-conformance"
