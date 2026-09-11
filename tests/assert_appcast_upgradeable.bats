#!/usr/bin/env bats
# Tests for scripts/assert_appcast_upgradeable.sh -- the "auto-update will see this as newer" gate.
# A local fixture repo with prior -mavericks.N tags stands in for a release history; no network, no
# Sparkle framework (the gate reasons over the numeric domain SUStandardVersionComparator orders).

setup() {
  GATE="$BATS_TEST_DIRNAME/../scripts/assert_appcast_upgradeable.sh"
  WORK="$(mktemp -d -t appcast_upgradeable_test)"
  REPO="$WORK/repo"; mkdir -p "$REPO"
  git -C "$REPO" init -q
  git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
  git -C "$REPO" commit -q --allow-empty -m init
  git -C "$REPO" tag 1.102.0-mavericks.6
  git -C "$REPO" tag 1.102.0-mavericks.7
}
teardown() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; }

# write an appcast carrying $1 as <sparkle:version>, echo its path
appcast() {
  f="$WORK/appcast.xml"
  printf '<rss><channel><item><sparkle:version>%s</sparkle:version></item></channel></rss>\n' "$1" > "$f"
  echo "$f"
}

@test "numeric and greater than the highest prior tag: passes" {
  run sh -c "cd '$REPO' && sh '$GATE' --appcast '$(appcast 1.102.0.8)' --version 1.102.0-mavericks.8"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '> previous 1.102.0.7'
}

@test "the shipped bug shape (sparkle:version still carries -mavericks.N): rejected" {
  run sh -c "cd '$REPO' && sh '$GATE' --appcast '$(appcast 1.102.0-mavericks.8)' --version 1.102.0-mavericks.8"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'not purely dotted-numeric'
}

@test "numeric but not greater (re-cut an existing N): rejected" {
  run sh -c "cd '$REPO' && sh '$GATE' --appcast '$(appcast 1.102.0.7)' --version 1.102.0-mavericks.7x"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'does NOT order after previous'
}

@test "lower than the highest prior tag: rejected" {
  run sh -c "cd '$REPO' && sh '$GATE' --appcast '$(appcast 1.102.0.6)' --version 1.102.0-mavericks.6x"
  [ "$status" -ne 0 ]
}

@test "N=10 beats N=9 (numeric, not lexical): passes" {
  git -C "$REPO" tag 1.102.0-mavericks.9
  run sh -c "cd '$REPO' && sh '$GATE' --appcast '$(appcast 1.102.0.10)' --version 1.102.0-mavericks.10"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '> previous 1.102.0.9'
}

@test "first release (no prior tags): skips ordering, but says so" {
  empty="$WORK/empty"; mkdir -p "$empty"; git -C "$empty" init -q
  run sh -c "cd '$empty' && sh '$GATE' --appcast '$(appcast 1.0.0.1)' --version 1.0.0-mavericks.1"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'first release'
}

@test "not a git checkout: fails rather than skipping silently" {
  run sh -c "cd '$WORK' && sh '$GATE' --appcast '$(appcast 1.0.0.1)' --version 1.0.0-mavericks.1"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'refusing to skip silently'
}

# --- --tag-glob: a repo whose tags are NOT <upstream>-mavericks.N ---------------------------------
# shipyard tags vX.Y.Z. Without --tag-glob the default scope finds none of them, so every release
# would take the "first release" exit -- the silent no-op this gate exists to refuse. The call below
# is the one shipyard's release.yml makes; 'v*.*.*' also keeps out the moving major tag (v1).

@test "default scope ignores v-tags (--tag-glob is opt-in; default behaviour unchanged)" {
  empty="$WORK/vonly"; mkdir -p "$empty"; git -C "$empty" init -q
  git -C "$empty" config user.email t@t; git -C "$empty" config user.name t
  git -C "$empty" commit -q --allow-empty -m init
  git -C "$empty" tag v1.0.135
  run sh -c "cd '$empty' && sh '$GATE' --appcast '$(appcast 1.0.0.1)' --version 1.0.0-mavericks.1"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'first release'
}

@test "default scope still skips a stray v-prefixed twin of a -mavericks.N tag" {
  # legacysupport really has v1.5.2-mavericks.1 beside 1.5.2-mavericks.1. Re-running the release it
  # names must still compare against the PREDECESSOR, not against its own twin.
  git -C "$REPO" tag v1.102.0-mavericks.8
  run sh -c "cd '$REPO' && sh '$GATE' --appcast '$(appcast 1.102.0.8)' --version 1.102.0-mavericks.8"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '> previous 1.102.0.7'
}

@test "--tag-glob: a higher previous v-tag rejects the release" {
  git -C "$REPO" tag v1.0.134; git -C "$REPO" tag v1.0.135
  run sh -c "cd '$REPO' && sh '$GATE' --appcast '$(appcast 1.0.134)' --version v1.0.134x --tag-glob 'v*.*.*'"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'does NOT order after previous 1.0.135 (from tag v1.0.135)'
}

@test "--tag-glob: a lower previous v-tag passes, naming the previous tag" {
  git -C "$REPO" tag v1.0.134; git -C "$REPO" tag v1.0.135
  run sh -c "cd '$REPO' && sh '$GATE' --appcast '$(appcast 1.0.136)' --version v1.0.136 --tag-glob 'v*.*.*'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '> previous 1.0.135 (tag v1.0.135)'
}

@test "--tag-glob: numeric, not lexical (v1.0.10 beats v1.0.9)" {
  git -C "$REPO" tag v1.0.9; git -C "$REPO" tag v1.0.10
  run sh -c "cd '$REPO' && sh '$GATE' --appcast '$(appcast 1.0.9)' --version v1.0.9x --tag-glob 'v*.*.*'"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'previous 1.0.10 (from tag v1.0.10)'
}

@test "--tag-glob: --version equal to an existing v-tag is excluded (a re-run compares to its predecessor)" {
  git -C "$REPO" tag v1.0.134; git -C "$REPO" tag v1.0.135
  run sh -c "cd '$REPO' && sh '$GATE' --appcast '$(appcast 1.0.135)' --version v1.0.135 --tag-glob 'v*.*.*'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '> previous 1.0.134 (tag v1.0.134)'
}

@test "--tag-glob 'v*.*.*': the moving major tag v1 is not a release" {
  git -C "$REPO" tag v1
  run sh -c "cd '$REPO' && sh '$GATE' --appcast '$(appcast 1.0.1)' --version v1.0.1 --tag-glob 'v*.*.*'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'first release'
  ! echo "$output" | grep -q 'tag v1)'
}

@test "--tag-glob: the -mavericks.N tags of the default scope are out of scope" {
  git -C "$REPO" tag v1.0.5
  run sh -c "cd '$REPO' && sh '$GATE' --appcast '$(appcast 1.0.6)' --version v1.0.6 --tag-glob 'v*.*.*'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '> previous 1.0.5 (tag v1.0.5)'
}

@test "--tag-glob with no matching tags: first release, and says which scope" {
  run sh -c "cd '$REPO' && sh '$GATE' --appcast '$(appcast 1.0.1)' --version v1.0.1 --tag-glob 'v*.*.*'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "first release"
  echo "$output" | grep -q "v\*\.\*\.\*"
}

@test "--tag-glob and --upstream-glob together: refused as ambiguous" {
  run sh -c "cd '$REPO' && sh '$GATE' --appcast '$(appcast 1.0.1)' --version v1.0.1 --tag-glob 'v*.*.*' --upstream-glob '1.26.*'"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q 'not both'
}
