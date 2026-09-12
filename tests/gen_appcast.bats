#!/usr/bin/env bats

setup() { SCRIPT="${BATS_TEST_DIRNAME}/../scripts/gen_appcast.sh"; }

@test "render-notes converts markdown subset to html" {
  printf '## Head\n\n- one\n- two\n\n**bold** and *em*\n' > "$BATS_TMPDIR/n.md"
  run sh "$SCRIPT" --render-notes "$BATS_TMPDIR/n.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"<h2>Head</h2>"* ]] || false
  [[ "$output" == *"<li>one</li>"* ]] || false
  [[ "$output" == *"<strong>bold</strong>"* ]] || false
}

@test "render-notes turns generated sections and links into html, not raw markdown" {
  # upstream-notes.sh and ingredient-notes.sh emit these; Sparkle's WebView would otherwise show
  # a literal '### Upstream' and '[text](url)'.
  printf '### Upstream\n\n- [Upstream release notes for 1.2.3](https://example.com/a?b=1&c=2#go1.2.3)\n' \
    > "$BATS_TMPDIR/n.md"
  run sh "$SCRIPT" --render-notes "$BATS_TMPDIR/n.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"<h3>Upstream</h3>"* ]] || false
  [[ "$output" == *'<li><a href="https://example.com/a?b=1&amp;c=2#go1.2.3">Upstream release notes for 1.2.3</a></li>'* ]] || false
  [[ "$output" != *"]("* ]] || false
}

@test "render-notes leaves brackets that are not a link alone" {
  printf 'see [the docs] (later) and *em*\n' > "$BATS_TMPDIR/n.md"
  run sh "$SCRIPT" --render-notes "$BATS_TMPDIR/n.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"see [the docs] (later) and <em>em</em>"* ]] || false
}

@test "render-notes renders the footer's --- thematic break as <hr>, not literal text" {
  # release-notes.sh always emits a bare '---' line to separate the footer from the body. GitHub
  # renders that as a horizontal rule; the awk renderer must too, or the two consumers disagree.
  printf '### What changed\n- Repackage of upstream OpenSSH 9.9p2; packaging changes only.\n\n---\nRequires Mac OS X 10.9.5 or later.\n[All changes since 9.9p2-mavericks.5](https://example.com/compare/a...b)\n' \
    > "$BATS_TMPDIR/n.md"
  run sh "$SCRIPT" --render-notes "$BATS_TMPDIR/n.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"<hr>"* ]] || false
  [[ "$output" != *"---"* ]] || false
  [[ "$output" == *'<p>Requires Mac OS X 10.9.5 or later. <a href="https://example.com/compare/a...b">All changes since 9.9p2-mavericks.5</a></p>'* ]] || false
  # the footer text must be its OWN <p>, not folded into the preceding "What changed" bullet/paragraph
  [[ "$output" != *"packaging changes only. Requires"* ]] || false
}

@test "render-notes renders a self-upstream's bare trailing --- as <hr>, not <p>---</p>" {
  # A self-upstream product has no floor line and no compare link, so the footer is JUST the rule.
  printf '### What changed\n- Release of Porthole 20260802.6.\n\n---\n' > "$BATS_TMPDIR/n.md"
  run sh "$SCRIPT" --render-notes "$BATS_TMPDIR/n.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"<hr>"* ]] || false
  [[ "$output" != *"<p>---</p>"* ]] || false
}

@test "channel title is parameterized" {
  printf 'notes\n' > "$BATS_TMPDIR/n.md"
  run sh "$SCRIPT" "My Product" "1.2.3" "http://x/y.pkg" "10.9.5" "$BATS_TMPDIR/n.md" 'length="1"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"<title>My Product</title>"* ]] || false
  [[ "$output" == *"<sparkle:version>1.2.3</sparkle:version>"* ]] || false
}

# Sparkle's comparator can't order "-mavericks.N", so <sparkle:version> (the compared value) must be
# numeric-only (X.Y.Z.N) while the human string stays in shortVersionString. Without this, same-upstream
# repackages are invisible to auto-update. Regression guard for that bug.
@test "sparkle:version is numeric-only for a -mavericks.N version; short string stays pretty" {
  printf 'notes\n' > "$BATS_TMPDIR/n.md"
  run sh "$SCRIPT" "P" "1.102.0-mavericks.4" "http://x/y.pkg" "10.9.5" "$BATS_TMPDIR/n.md" 'length="1"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"<sparkle:version>1.102.0.4</sparkle:version>"* ]] || false
  [[ "$output" == *"<sparkle:shortVersionString>1.102.0-mavericks.4</sparkle:shortVersionString>"* ]] || false
  [[ "$output" != *"<sparkle:version>1.102.0-mavericks.4</sparkle:version>"* ]] || false
}

# A monotonic OpenSSH-portable "pN" patch (p2 is NEWER than p1) normalizes to dotted-numeric, so
# auto-update orders it; the pretty "9.9p2" stays in the short string. (openssh is the family's first
# letter-in-upstream case.)
@test "sparkle:version normalizes an OpenSSH-portable pN patch to dotted-numeric" {
  printf 'notes\n' > "$BATS_TMPDIR/n.md"
  run sh "$SCRIPT" "P" "9.9p2-mavericks.1" "http://x/y.pkg" "10.9.5" "$BATS_TMPDIR/n.md" 'length="1"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"<sparkle:version>9.9.2.1</sparkle:version>"* ]] || false
  [[ "$output" == *"<sparkle:shortVersionString>9.9p2-mavericks.1</sparkle:shortVersionString>"* ]] || false
}

# A NON-monotonic prerelease letter (rc1 means OLDER than the release) must NOT be silently dot-joined
# -- the gate still fails closed so a human maps it into a lower numeric band instead.
@test "a non-monotonic prerelease letter still fails closed" {
  printf 'notes\n' > "$BATS_TMPDIR/n.md"
  run sh "$SCRIPT" "P" "1.2.3rc1-mavericks.1" "http://x/y.pkg" "10.9.5" "$BATS_TMPDIR/n.md" 'length="1"'
  [ "$status" -ne 0 ]
  [[ "$output" == *"not purely dotted-numeric"* ]] || false
}
