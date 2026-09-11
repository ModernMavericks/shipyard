bats_require_minimum_version 1.5.0

# assert_tag_publishable.sh VERSION REPO_URL REF_TYPE REF_NAME SHA -- publish-release.yml's guard.
#
# Two runs can compute the same -mavericks.(N+1) and both build it; the loser must NOT publish, and
# must not relabel either (the version is already baked into pkgbuild --version, the pkg filename and
# the appcast's <sparkle:version>). So an existing tag refuses the publish.
#
# But a run TRIGGERED BY a pushed tag always finds its own tag: that is what started it. Refusing
# there left every tag-published repo unable to release at all (clang had no other path). That case is
# allowed, and only that case: the run's ref must be the tag, and the tag must point at the commit
# being published.
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  T="$BATS_TEST_TMPDIR"
  git init -q "$T/remote"
  (cd "$T/remote" && git config user.email t@example.invalid && git config user.name t \
     && echo one > a && git add a && git commit -qm one \
     && git tag 1.0.0-mavericks.1 \
     && echo two > a && git commit -qam two)
  URL="$T/remote"
  TAGGED="$(git -C "$T/remote" rev-parse 1.0.0-mavericks.1)"
  HEAD_SHA="$(git -C "$T/remote" rev-parse HEAD)"
}
guard() { sh "$ROOT/scripts/assert_tag_publishable.sh" "$@"; }

@test "a free tag publishes" {
  run --separate-stderr guard 1.0.0-mavericks.2 "$URL" branch main "$HEAD_SHA"
  [ "$status" -eq 0 ]
}

@test "a tag another run already published refuses, and says to re-dispatch" {
  run --separate-stderr guard 1.0.0-mavericks.1 "$URL" branch main "$HEAD_SHA"
  [ "$status" -eq 1 ]
  [[ "$output$stderr" == *"already exists"* ]] || false
  [[ "$output$stderr" == *"e-dispatch"* ]] || false
}

@test "the tag that TRIGGERED this run publishes: it points at the commit being published" {
  run --separate-stderr guard 1.0.0-mavericks.1 "$URL" tag 1.0.0-mavericks.1 "$TAGGED"
  [ "$status" -eq 0 ]
  [[ "$output$stderr" == *"triggered"* ]] || false
}

@test "a tag run publishing a DIFFERENT version than its own tag refuses" {
  run --separate-stderr guard 1.0.0-mavericks.1 "$URL" tag some-other-tag "$TAGGED"
  [ "$status" -eq 1 ]
}

@test "a tag run whose tag points somewhere else refuses" {
  run --separate-stderr guard 1.0.0-mavericks.1 "$URL" tag 1.0.0-mavericks.1 "$HEAD_SHA"
  [ "$status" -eq 1 ]
  [[ "$output$stderr" == *"points at"* ]] || false
}

@test "an annotated tag is recognised by the commit it points at" {
  (cd "$T/remote" && git tag -a -m v 1.0.0-mavericks.3 HEAD)
  run --separate-stderr guard 1.0.0-mavericks.3 "$URL" tag 1.0.0-mavericks.3 "$HEAD_SHA"
  [ "$status" -eq 0 ]
}

@test "a remote it cannot read refuses rather than publish blind" {
  run --separate-stderr guard 1.0.0-mavericks.2 "$T/no-such-repo" branch main "$HEAD_SHA"
  [ "$status" -eq 1 ]
  [[ "$output$stderr" == *"could not read tags"* ]] || false
}
