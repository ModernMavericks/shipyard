#!/bin/sh
# Generate the Sparkle appcast.xml for ONE release, to stdout.
#
#   gen_appcast.sh <channel-title> <version> <pkg-url> <min-os> <notes-file> <enclosure-attrs>
#   gen_appcast.sh --render-notes <notes-file>      # emit just the HTML fragment (test seam)
#
# Release notes (docs/release-notes/vX.Y.Z.md) are rendered from Markdown to HTML and inlined into the
# <description> CDATA. Sparkle 1.x shows the <description> in a WebView, which treats the CDATA as HTML;
# feeding it raw Markdown collapsed the notes into one line-joined blob, so we convert here.
#
# The renderer is deliberately dependency-free (pure awk) so it runs identically on the 10.9 dev box's
# BSD/BWK awk and on a modern CI runner -- NO pandoc/cmark. It handles exactly the subset our notes use:
#   `## Heading`            -> <h2>Heading</h2>
#   `### Heading`           -> <h3>Heading</h3>       (the generated upstream/ingredient sections)
#   contiguous `- ` bullets -> <ul><li>...</li></ul>   (continuation lines fold into the item)
#   `[text](scheme:url)`    -> <a href="...">text</a>  (upstream-notes.sh links upstream's notes)
#   `**bold**`              -> <strong>bold</strong>
#   `*italic*`              -> <em>italic</em>
#   `---` on its own line   -> <hr>                     (release-notes.sh's footer rule)
#   blank-line-separated prose (incl. the trailing `Requires...`) -> <p>...</p>
#
# <enclosure-attrs> is the `sparkle:edSignature="..." length="..."` string that `sign_update -s <key>
# <pkg>` prints -- passed in, so THIS script needs no signing key (sign_update is a modern Swift binary
# that can't run on the 10.9 box) and stays a pure text transform, unit-testable via --render-notes.
#
# Fails if the notes file is missing or empty: the notes ARE the release's <description>, and a
# release with no notes is a mistake we want to catch (mirrors the CI + pre-push gate).
set -eu

# Render a Markdown notes file to an HTML fragment on stdout. Pure awk; see the subset above.
md_to_html() {
  awk '
    function esc(s) {                       # HTML-escape before we inject our own tags
      gsub(/&/, "\\&amp;", s)
      gsub(/</, "\\&lt;",  s)
      gsub(/>/, "\\&gt;",  s)
      return s
    }
    function inline(s,   r, before, m, i) { # links, **bold**, *italic* (BWK awk: no gensub backrefs)
      s = esc(s)
      r = ""
      # Only a scheme-qualified target is a link, so prose like "[the docs] (later)" stays prose.
      # The URL was escaped above, which is exactly what an href attribute wants (&amp;).
      while (match(s, /\[[^]]+\]\([a-z]+:[^) ]+\)/)) {
        before = substr(s, 1, RSTART - 1)
        m = substr(s, RSTART + 1, RLENGTH - 2)          # text](url
        i = index(m, "](")
        r = r before "<a href=\"" substr(m, i + 2) "\">" substr(m, 1, i - 1) "</a>"
        s = substr(s, RSTART + RLENGTH)
      }
      s = r s
      r = ""
      while (match(s, /\*\*[^*]+\*\*/)) {
        before = substr(s, 1, RSTART - 1)
        m = substr(s, RSTART + 2, RLENGTH - 4)
        r = r before "<strong>" m "</strong>"
        s = substr(s, RSTART + RLENGTH)
      }
      s = r s
      r = ""
      while (match(s, /\*[^*]+\*/)) {
        before = substr(s, 1, RSTART - 1)
        m = substr(s, RSTART + 1, RLENGTH - 2)
        r = r before "<em>" m "</em>"
        s = substr(s, RSTART + RLENGTH)
      }
      return r s
    }
    function flush_li() { if (li != "") { print "<li>" inline(li) "</li>"; li = "" } }
    function close_block() {
      if (mode == "p")  { if (p != "") print "<p>" inline(p) "</p>"; p = "" }
      else if (mode == "ul") { flush_li(); print "</ul>" }
      mode = ""
    }
    { line = $0 }
    line ~ /^[[:space:]]*$/ { close_block(); next }         # blank line closes the current block
    line ~ /^## / {                                         # heading
      close_block()
      print "<h2>" inline(substr(line, 4)) "</h2>"
      next
    }
    line ~ /^### / {
      close_block()
      print "<h3>" inline(substr(line, 5)) "</h3>"
      next
    }
    line ~ /^- / {                                          # bullet item start
      if (mode == "p") close_block()
      if (mode != "ul") { print "<ul>"; mode = "ul" }
      flush_li()
      li = substr(line, 3)
      next
    }
    line ~ /^---[[:space:]]*$/ { close_block(); print "<hr>"; next }   # thematic break (footer rule)
    {                                                       # prose / continuation line
      sub(/^[[:space:]]+/, "", line)
      if (mode == "ul") { li = li " " line }
      else { mode = "p"; p = (p == "" ? line : p " " line) }
    }
    END { close_block() }
  ' "$1"
}

if [ "${1:-}" = "--render-notes" ]; then
  [ $# -eq 2 ] || { echo "usage: gen_appcast.sh --render-notes <notes-file>" >&2; exit 2; }
  [ -f "$2" ] || { echo "release notes not found: $2" >&2; exit 1; }
  [ -s "$2" ] || { echo "release notes empty: $2" >&2; exit 1; }
  md_to_html "$2"
  exit 0
fi

SELF="$(cd "$(dirname "$0")" && pwd)"
. "$SELF/lib.sh"          # comparison_key()

[ $# -eq 6 ] || { echo "usage: gen_appcast.sh <channel-title> <version> <pkg-url> <min-os> <notes-file> <enclosure-attrs>" >&2; exit 2; }
CHANNEL_TITLE="$1"; VER="$2"; URL="$3"; MINOS="$4"; NOTES_FILE="$5"; ENCLOSURE_ATTRS="$6"

# Sparkle's SUStandardVersionComparator can't order the "-mavericks.N" suffix (it reads 1.2.3-mavericks.3
# and .4 as EQUAL), so <sparkle:version> -- the value it COMPARES against the app's CFBundleVersion -- must
# be numeric-only. Turn "-mavericks." into ".", e.g. 1.102.0-mavericks.4 -> 1.102.0.4. Also normalize an
# OpenSSH-portable-style "pN" patch (X.YpZ, where pZ INCREASES the version) to ".N": 9.9p2 -> 9.9.2, which
# is order-preserving (9.9p2 < 9.10p1 stays 9.9.2 < 9.10.1). The human string stays in
# <sparkle:shortVersionString>. The derivation itself is lib.sh's comparison_key(); MavericksSparkle.cmake mirrors it.
BUILD_VER=$(comparison_key "$VER")

# Fail if the derived key is not purely dotted-numeric (X.Y.Z.N): SUStandardVersionComparator only
# totally orders that domain, and every "update says I'm up to date" bug lived OUTSIDE it (a stray
# letter or an unstripped "-mavericks." makes two versions compare EQUAL). Catch it here, at the source
# every product's appcast flows through, rather than discovering it live weeks later. The monotonic
# "> previous release" half is assert_appcast_upgradeable.sh, which needs the prior release to compare.
case "$BUILD_VER" in
  ''|.*|*.|*..*|*[!0-9.]*)
    echo "gen_appcast: sparkle:version '$BUILD_VER' (from version '$VER') is not purely dotted-numeric --" >&2
    echo "  SUStandardVersionComparator can only order X.Y.Z.N, so auto-update would misfire on it." >&2
    exit 1;;
esac

[ -f "$NOTES_FILE" ] || { echo "release notes not found: $NOTES_FILE" >&2; exit 1; }
[ -s "$NOTES_FILE" ] || { echo "release notes empty: $NOTES_FILE" >&2; exit 1; }

# RFC-822 pubDate in UTC (Sparkle sorts items by it).
PUBDATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")

cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>$CHANNEL_TITLE</title>
    <item>
      <title>Version $VER</title>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$BUILD_VER</sparkle:version>
      <sparkle:shortVersionString>$VER</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINOS</sparkle:minimumSystemVersion>
      <description><![CDATA[
<style>body{font-family:"Helvetica Neue",Helvetica,Arial,sans-serif;font-size:13px;}</style>
$(md_to_html "$NOTES_FILE")
]]></description>
      <enclosure url="$URL" type="application/octet-stream" $ENCLOSURE_ATTRS />
    </item>
  </channel>
</rss>
XML
