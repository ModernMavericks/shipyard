#!/bin/sh
# The conventions gate. Each check must fail on its own, and a compliant repo must pass cleanly.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
S="$here/../scripts/check-family-conventions.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/family-conventions.XXXXXX")"; trap 'rm -rf "$work"' EXIT  # template: 10.9 BSD mktemp requires one

mkrepo() {  # $1 = dir
  mkdir -p "$1/.github/workflows" "$1/tests"
  cat > "$1/.github/workflows/release.yml" <<'YML'
name: release
on:
  push:
    tags: ['*-mavericks.*']
concurrency:
  group: release-${{ github.event_name == 'pull_request' && github.ref || github.run_id }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
jobs:
  build:
    steps:
      - run: sh "$SHIPYARD_SCRIPTS/run-repo-tests.sh"
      - run: gh release create "$TAG" dist/* --notes-file "$NOTES"
YML
  printf '# Build ingredients\n' > "$1/INGREDIENTS.md"
  printf '{"extends":["github>ModernMavericks/shipyard"]}\n' > "$1/.github/renovate.json"
  printf '#!/bin/sh\nexit 0\n' > "$1/tests/a-test.sh"
  # A compliant repo commits UPSTREAM_VERSION and gitignores VERSION (a build product), and the gate
  # asks git what is tracked -- so the fixture has to be a real checkout.
  printf '1.0.0\n' > "$1/UPSTREAM_VERSION"
  printf '/VERSION\n' > "$1/.gitignore"
  # ...and says where upstream's own release notes live, for a release that ships a new upstream.
  mkdir -p "$1/build"
  printf '#!/bin/sh\nprintf "https://example.com/v%%s\\n" "$1"\n' > "$1/build/upstream-release-notes-url.sh"
  (cd "$1" && git init -q && git add -A) >/dev/null 2>&1
}

# compliant repo passes
mkrepo "$work/ok"; (cd "$work/ok" && sh "$S" >/dev/null) || { echo "FAIL compliant repo should pass"; exit 1; }

# no release.yml at all (shipyard itself) -> passes
mkdir -p "$work/norel"; (cd "$work/norel" && sh "$S" >/dev/null) || { echo "FAIL no-release.yml should pass"; exit 1; }

# 1. missing concurrency
mkrepo "$work/c"; grep -v -e '^concurrency:' -e '^  group:' -e '^  cancel-in-progress:' \
  "$work/ok/.github/workflows/release.yml" > "$work/c/.github/workflows/release.yml"
if (cd "$work/c" && sh "$S" >/dev/null 2>&1); then echo "FAIL missing concurrency should fail"; exit 1; fi
(cd "$work/c" && sh "$S" 2>&1 | grep -qi concurrency) || { echo "FAIL should name concurrency"; exit 1; }

# 1b. A release.yml whose concurrency group is IDENTICAL for every event cannot keep a publishing run
# out of a shared group. cancel-in-progress:false protects the RUNNING job and not the QUEUED one --
# GitHub keeps only the newest pending run per group -- so a queued dispatch is evicted by the next
# arrival and its release silently never happens. Must fail.
mkrepo "$work/cr"
python3 - "$work/cr/.github/workflows/release.yml" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace("  group: release-${{ github.event_name == 'pull_request' && github.ref || github.run_id }}",
            "  group: release-${{ github.ref }}")
s=s.replace("  cancel-in-progress: ${{ github.event_name == 'pull_request' }}",
            "  cancel-in-progress: false")
open(p,'w').write(s)
PY
if (cd "$work/cr" && sh "$S" >/dev/null 2>&1); then echo "FAIL: a single-group concurrency block should fail"; exit 1; fi
(cd "$work/cr" && sh "$S" 2>&1 | grep -qiE 'queued|pending|supersede') || { echo "FAIL: should explain the queued-run eviction"; exit 1; }

# ...and the block the family actually ships passes. Only pull_request supersedes (keyed per ref, so a
# force-push replaces its own predecessor); a branch push, a tag and a dispatch are each keyed per RUN
# and alone in their group. Folded across lines, because that is how it is written in the repos.
mkrepo "$work/cok"
python3 - "$work/cok/.github/workflows/release.yml" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace("  group: release-${{ github.event_name == 'pull_request' && github.ref || github.run_id }}",
            "  group: >-\n"
            "    release-${{ github.event_name == 'pull_request'\n"
            "                && github.ref || github.run_id }}")
open(p,'w').write(s)
PY
(cd "$work/cok" && sh "$S" >/dev/null) || { echo "FAIL: the shipped concurrency block should pass"; exit 1; }

# ...and so must the shape this family actually ran until 2026-09-09: dispatches herded into one
# shared literal group with cancel-in-progress:false. It mentions github.event_name, so a check that
# only asks "does the group distinguish events?" waves it straight through -- yet it is the exact
# arrangement that evicted a queued run in mavericks-golang. The gate has to reject it by name.
mkrepo "$work/cold"
python3 - "$work/cold/.github/workflows/release.yml" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace("  group: release-${{ github.event_name == 'pull_request' && github.ref || github.run_id }}",
            "  group: ${{ github.workflow }}-${{ github.event_name == 'workflow_dispatch' && 'local_release' || github.ref }}")
s=s.replace("  cancel-in-progress: ${{ github.event_name == 'pull_request' }}",
            "  cancel-in-progress: ${{ github.event_name != 'workflow_dispatch' }}")
open(p,'w').write(s)
PY
if (cd "$work/cold" && sh "$S" >/dev/null 2>&1); then echo "FAIL: the old shared-dispatch-group shape should fail"; exit 1; fi
(cd "$work/cold" && sh "$S" 2>&1 | grep -qiE 'run_id|per run|alone') || { echo "FAIL: should say publishing runs must be keyed per run"; exit 1; }

# A group that IS per-run but still lets a publish be cancelled is only half the rule.
mkrepo "$work/chalf"
python3 - "$work/chalf/.github/workflows/release.yml" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace("  cancel-in-progress: ${{ github.event_name == 'pull_request' }}",
            "  cancel-in-progress: true")
open(p,'w').write(s)
PY
if (cd "$work/chalf" && sh "$S" >/dev/null 2>&1); then echo "FAIL: a cancellable publish should fail"; exit 1; fi
(cd "$work/chalf" && sh "$S" 2>&1 | grep -qi 'pull_request') || { echo "FAIL: should say only a pull_request may be cancelled"; exit 1; }

# 2. tests exist but CI never runs them
mkrepo "$work/t"; grep -v 'run-repo-tests' "$work/ok/.github/workflows/release.yml" > "$work/t/.github/workflows/release.yml"
if (cd "$work/t" && sh "$S" >/dev/null 2>&1); then echo "FAIL unrun tests should fail"; exit 1; fi

# ...but a repo with an EMPTY tests dir is fine
mkrepo "$work/te"; rm -f "$work/te/tests/a-test.sh"
grep -v 'run-repo-tests' "$work/ok/.github/workflows/release.yml" > "$work/te/.github/workflows/release.yml"
(cd "$work/te" && sh "$S" >/dev/null) || { echo "FAIL empty tests dir should pass"; exit 1; }

# 3. missing INGREDIENTS.md
mkrepo "$work/i"; rm -f "$work/i/INGREDIENTS.md"
if (cd "$work/i" && sh "$S" >/dev/null 2>&1); then echo "FAIL missing INGREDIENTS.md should fail"; exit 1; fi

# 4. a Renovate key restating the preset's own value is redundant -> fail
mkrepo "$work/r"
printf '{"extends":["github>ModernMavericks/shipyard"],"ignoreTests":false}\n' > "$work/r/.github/renovate.json"
if (cd "$work/r" && sh "$S" >/dev/null 2>&1); then echo "FAIL redundant renovate key should fail"; exit 1; fi
(cd "$work/r" && sh "$S" 2>&1 | grep -qi ignoreTests) || { echo "FAIL should name the key"; exit 1; }

# ...but the SAME key with a DIFFERENT value is a deliberate override, not drift. A repo with no build
# to gate legitimately opts back into blind automerge with ignoreTests:true; the gate must allow it.
mkrepo "$work/r2"
printf '{"extends":["github>ModernMavericks/shipyard"],"ignoreTests":true}\n' > "$work/r2/.github/renovate.json"
(cd "$work/r2" && sh "$S" >/dev/null) || { echo "FAIL deliberate ignoreTests:true override should pass"; exit 1; }

# 5. release publishes no notes
mkrepo "$work/n"; grep -v 'notes-file' "$work/ok/.github/workflows/release.yml" > "$work/n/.github/workflows/release.yml"
if (cd "$work/n" && sh "$S" >/dev/null 2>&1); then echo "FAIL no notes should fail"; exit 1; fi

# An automerge exception must say WHY. The family default is ship-if-green (patch, minor and major
# alike); a repo restricts automerge only where a bad bump would build fine and be wrong -- the case a
# green build cannot catch. Unexplained, that is indistinguishable from drift.
mkrepo "$work/am"
printf '%s\n' '{"extends":["github>ModernMavericks/shipyard"],"packageRules":[{"matchDepNames":["x"],"matchUpdateTypes":["minor"],"automerge":false}]}' \
  > "$work/am/.github/renovate.json"
if (cd "$work/am" && sh "$S" >/dev/null 2>&1); then echo "FAIL undescribed automerge exception should fail"; exit 1; fi
(cd "$work/am" && sh "$S" 2>&1 | grep -qi 'automerge') || { echo "FAIL should name the automerge rule"; exit 1; }

# ...with a reason, it passes
mkrepo "$work/am2"
printf '%s\n' '{"extends":["github>ModernMavericks/shipyard"],"packageRules":[{"description":"A minor bump needs LLVM_BRANCH to follow, which no regex can infer: it would build fine and be wrong.","matchDepNames":["x"],"matchUpdateTypes":["minor"],"automerge":false}]}' \
  > "$work/am2/.github/renovate.json"
(cd "$work/am2" && sh "$S" >/dev/null) || { echo "FAIL described exception should pass"; exit 1; }

# a rule that does NOT touch automerge (e.g. allowedVersions) needs no such reason
mkrepo "$work/am3"
printf '%s\n' '{"extends":["github>ModernMavericks/shipyard"],"packageRules":[{"matchDepNames":["x"],"allowedVersions":"/^v?[0-9.]+$/"}]}' \
  > "$work/am3/.github/renovate.json"
(cd "$work/am3" && sh "$S" >/dev/null) || { echo "FAIL non-automerge rule should pass"; exit 1; }

# a repo that publishes via the shared workflow satisfies the notes check: the caller has no
# --notes-file or body_path of its own, because publish-release.yml owns the body (and fails on an
# empty one, which is stronger than what this check can see).
mkrepo "$work/p"
python3 - "$work/p/.github/workflows/release.yml" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace('      - run: gh release create "$TAG" dist/* --notes-file "$NOTES"\n',
            '  publish:\n'
            '    uses: ModernMavericks/shipyard/.github/workflows/publish-release.yml@v1\n'
            '    with: { version: "1.0.0", artifact: pkg }\n')
open(p,'w').write(s)
PY
(cd "$work/p" && sh "$S" >/dev/null) || { echo "FAIL publish-release caller should satisfy the notes check"; exit 1; }

# tests may be run from a DIFFERENT workflow (tailscale runs ctest from ci.yml, not release.yml)
mkrepo "$work/x"; grep -v 'run-repo-tests' "$work/ok/.github/workflows/release.yml" > "$work/x/.github/workflows/release.yml"
printf 'name: CI\njobs:\n  build:\n    steps:\n      - run: ctest --preset cross\n' > "$work/x/.github/workflows/ci.yml"
(cd "$work/x" && sh "$S" >/dev/null) || { echo "FAIL tests run from ci.yml should pass"; exit 1; }

# 7. VERSION must not be committed. The shipped state lives in tags; a committed VERSION is a second
# answer to "what version is this?", and it drifts -- container-tools built -mavericks.14 from a file
# that still said .2, which also made its tag-triggered publish path (tag must equal VERSION)
# unsatisfiable. UPSTREAM_VERSION is the committed input; VERSION is derived from it plus the tags.
mkrepo "$work/v1"
(cd "$work/v1" && sh "$S" >/dev/null) || { echo "FAIL derived-version repo should pass"; exit 1; }

# a TRACKED VERSION file fails, and the message says which file and what to do
mkrepo "$work/v2"
printf '1.0.0-mavericks.3\n' > "$work/v2/VERSION"
(cd "$work/v2" && git add -f VERSION) >/dev/null 2>&1
if out="$(cd "$work/v2" && sh "$S" 2>&1)"; then echo "FAIL tracked VERSION should fail"; exit 1; fi
printf '%s\n' "$out" | grep -q 'VERSION' || { echo "FAIL should name VERSION: $out"; exit 1; }

# an untracked VERSION (a build product sitting in the tree) is FINE -- that is the normal state
# after any local build, and failing on it would make the gate unrunnable on a developer's machine
mkrepo "$work/v3"
printf '1.0.0-mavericks.3\n' > "$work/v3/VERSION"
(cd "$work/v3" && sh "$S" >/dev/null) || { echo "FAIL untracked VERSION should pass"; exit 1; }

# no upstream input at all: nothing can derive a version, so say so rather than let CI discover it
mkrepo "$work/v4"; rm "$work/v4/UPSTREAM_VERSION"
if out="$(cd "$work/v4" && sh "$S" 2>&1)"; then echo "FAIL missing upstream input should fail"; exit 1; fi
printf '%s\n' "$out" | grep -q 'UPSTREAM_VERSION' || { echo "FAIL should name UPSTREAM_VERSION: $out"; exit 1; }

# a repo whose upstream is DERIVED from its pin (ed25519: the pinned commit's date; tailscale: the
# upstream's own VERSION.txt) has no committed UPSTREAM_VERSION and must still pass
mkrepo "$work/v5"; rm "$work/v5/UPSTREAM_VERSION"
mkdir -p "$work/v5/build"; printf '#!/bin/sh\n: > UPSTREAM_VERSION\n' > "$work/v5/build/derive-upstream-version.sh"
(cd "$work/v5" && git add -A) >/dev/null 2>&1
(cd "$work/v5" && sh "$S" >/dev/null) || { echo "FAIL derived upstream should pass"; exit 1; }

# parallel upstream lines (golang) keep one UPSTREAM_VERSION per line. Check 7b additionally demands
# each line carry its OWN capped Renovate manager, so the fixture has to look like golang really does
# -- an anchored managerFilePatterns plus an allowedVersions cap keeping the line off the next minor.
mkrepo "$work/v6"; rm "$work/v6/UPSTREAM_VERSION"
mkdir -p "$work/v6/lines/126"; printf '1.26.5\n' > "$work/v6/lines/126/UPSTREAM_VERSION"
cat > "$work/v6/.github/renovate.json" <<'JSON'
{"extends":["github>ModernMavericks/shipyard"],
 "customManagers":[{"customType":"regex","managerFilePatterns":["/^lines/126/UPSTREAM_VERSION$/"],
                    "matchStrings":["^(?<currentValue>.+?)\\s*$"],"depNameTemplate":"go-126",
                    "packageNameTemplate":"go","datasourceTemplate":"golang-version"}],
 "packageRules":[{"matchDepNames":["go-126"],"allowedVersions":"<1.27"}]}
JSON
(cd "$work/v6" && git add -A) >/dev/null 2>&1
(cd "$work/v6" && sh "$S" >/dev/null) || { echo "FAIL per-line upstream should pass"; exit 1; }

# 7d. The mirror of 7c: a build OUTPUT dir that is NOT ignored. tailscale's release.yml configures the
# updater with `cmake -S updater -B build/updater`, a path the shared presets never name -- so nothing
# tied it to .gitignore, and 7.4MB of CMake output sat in the checkout untracked AND unignored, one
# `git add -A` from being committed. The gate finds the paths the repo itself names rather than
# demanding one blessed spelling: ten of fifteen repos spell their ignores differently and all are fine.
mkrepo "$work/bo"
cat >> "$work/bo/.github/workflows/release.yml" <<'YML'
      - run: cmake -S updater -B build/updater
YML
if (cd "$work/bo" && sh "$S" >/dev/null 2>&1); then echo "FAIL: an unignored build output dir should fail"; exit 1; fi
(cd "$work/bo" && sh "$S" 2>&1 | grep -q 'build/updater') || { echo "FAIL: should name the unignored path"; exit 1; }

# ...ignored, it passes. Any spelling that actually covers the path is fine.
mkrepo "$work/bok"
cat >> "$work/bok/.github/workflows/release.yml" <<'YML'
      - run: cmake -S updater -B build/updater
YML
printf 'build/updater/\n' >> "$work/bok/.gitignore"
(cd "$work/bok" && git add -A >/dev/null 2>&1; sh "$S" >/dev/null) || { echo "FAIL: an ignored build output dir should pass"; exit 1; }

# A build that already leaves the tree needs no ignore at all -- that is the point of leaving it.
mkrepo "$work/boo"
cat >> "$work/boo/.github/workflows/release.yml" <<'YML'
      - run: cmake -S . -B "$RUNNER_TEMP/b"
      - run: cmake -S . -B /tmp/build
YML
(cd "$work/boo" && git add -A >/dev/null 2>&1; sh "$S" >/dev/null) || { echo "FAIL: an out-of-tree build dir needs no ignore"; exit 1; }

# `grep -B 3` is not a build directory. The gate reads only cmake's -B, or it invents failures.
mkrepo "$work/bgrep"
cat >> "$work/bgrep/.github/workflows/release.yml" <<'YML'
      - run: grep -B 3 pattern file
YML
(cd "$work/bgrep" && git add -A >/dev/null 2>&1; sh "$S" >/dev/null) || { echo "FAIL: grep -B must not be read as a build dir"; exit 1; }

# A committed CMakePresets.json names binaryDirs too; those are build output just the same.
mkrepo "$work/bpre"
printf '{"version":6,"configurePresets":[{"name":"n","binaryDir":"${sourceDir}/build-native"}]}\n' \
  > "$work/bpre/CMakePresets.json"
if (cd "$work/bpre" && git add -A >/dev/null 2>&1; sh "$S" >/dev/null 2>&1); then echo "FAIL: an unignored preset binaryDir should fail"; exit 1; fi
(cd "$work/bpre" && sh "$S" 2>&1 | grep -q 'build-native') || { echo "FAIL: should name the preset binaryDir"; exit 1; }

# 7d, the way it actually runs: family-conventions.yml checks shipyard out to .shipyard/ INSIDE the
# consumer's workspace and runs the gate from there. A sweep of "*.sh" therefore reads the gate's OWN
# source -- whose comments explain the rule using `cmake -S updater -B build/updater` and
# `cmake ... -B <dir>` as examples. The first draft reported those as unignored build directories and
# turned every consumer's conventions run red. Vendored shipyard is not this repo's build.
mkrepo "$work/bvend"
mkdir -p "$work/bvend/.shipyard/scripts"
cat > "$work/bvend/.shipyard/scripts/check-family-conventions.sh" <<'SH'
#!/bin/sh
# tailscale configured the updater with `cmake -S updater -B build/updater` -- a path the shared
# presets do not name -- so nothing tied it to .gitignore. Every `cmake ... -B <dir>` counts.
SH
(cd "$work/bvend" && git add -A >/dev/null 2>&1; sh "$S" >/dev/null) || { echo "FAIL: a vendored .shipyard/ must not be read as this repo's build"; exit 1; }

# ...and a COMMENT in the repo's own shell that merely mentions a cmake command line is prose, not a
# build. Only a line that actually runs cmake names a directory.
mkrepo "$work/bcomment"
cat > "$work/bcomment/note.sh" <<'SH'
#!/bin/sh
# Historically we ran `cmake -S . -B legacy-build` here; see the notes for why we stopped.
exit 0
SH
(cd "$work/bcomment" && git add -A >/dev/null 2>&1; sh "$S" >/dev/null) || { echo "FAIL: a commented-out cmake line is not a build dir"; exit 1; }

# 7d must read only what the repo COMMITS. An earlier draft swept the worktree with `find`, so it
# also read build output and the AppleDouble `._*.sh` files an NFS checkout collects -- 65 .sh swept
# against 58 tracked in shipyard itself. BSD sed aborts on their binary content ("RE error: illegal
# byte sequence"), which truncates the candidate stream mid-pipe: the check then silently stops
# looking, and an unignored build dir later in the sweep goes unreported. Tracked files only.
mkrepo "$work/buntracked"
printf '#!/bin/sh\ncmake -S . -B never-committed-build\n' > "$work/buntracked/stray.sh"
printf 'binary-\000-junk\n' > "$work/buntracked/._decoy.sh"
(cd "$work/buntracked" && sh "$S" >/dev/null 2>&1) || { echo "FAIL: an UNTRACKED .sh must not be scanned as this repo's build"; exit 1; }
(cd "$work/buntracked" && sh "$S" 2>&1 | grep -qi 'illegal byte sequence') && { echo "FAIL: a binary ._*.sh must not reach sed"; exit 1; }

# ...but once committed, the very same file counts.
(cd "$work/buntracked" && git add stray.sh >/dev/null 2>&1)
if (cd "$work/buntracked" && sh "$S" >/dev/null 2>&1); then echo "FAIL: a COMMITTED build script's dir must be required to be ignored"; exit 1; fi
(cd "$work/buntracked" && sh "$S" 2>&1 | grep -q 'never-committed-build') || { echo "FAIL: should name the tracked script's build dir"; exit 1; }

# 8. Workflow YAML must parse with DUPLICATE KEYS REJECTED. A second `with:` on one step is valid
# YAML (last key wins) and ordinary parsers accept it, but GitHub refuses to run the workflow: the run
# shows up named after the file path, "likely failed because of a workflow file issue", with no step
# logs at all. swift-runtime shipped exactly that.
mkrepo "$work/y1"
awk '{print} /^    steps:$/ && !d {print "      - uses: actions/checkout@v7"; print "        with:"; print "          fetch-depth: 0"; print "        with:"; print "          fetch-depth: 1"; d=1}' \
  "$work/ok/.github/workflows/release.yml" > "$work/y1/.github/workflows/release.yml"
if out="$(cd "$work/y1" && sh "$S" 2>&1)"; then echo "FAIL duplicate key should fail"; exit 1; fi
printf '%s\n' "$out" | grep -qi 'duplicate' || { echo "FAIL should say duplicate: $out"; exit 1; }

# malformed YAML fails too, naming the file
mkrepo "$work/y2"
printf 'name: x\non: [push]\njobs:\n  a:\n   steps:\n  - bad indent\n' > "$work/y2/.github/workflows/broken.yml"
if out="$(cd "$work/y2" && sh "$S" 2>&1)"; then echo "FAIL broken yaml should fail"; exit 1; fi
printf '%s\n' "$out" | grep -q 'broken.yml' || { echo "FAIL should name the file: $out"; exit 1; }

# ...and when PyYAML itself is missing, the gate must NAME the absent dependency rather than dump a
# ModuleNotFoundError traceback at a repo that is fully compliant. GitHub's macOS runner python3 ships
# without PyYAML, so this reported a bare "FAIL compliant repo should pass" on every CI run for a
# month, pointing at the repo instead of at the one `pip install` that fixes it.
mkrepo "$work/y3"
noyaml="$work/noyaml"; mkdir -p "$noyaml"
printf 'raise ImportError("No module named yaml")\n' > "$noyaml/yaml.py"
if out="$(cd "$work/y3" && PYTHONPATH="$noyaml" sh "$S" 2>&1)"; then
  echo "FAIL missing PyYAML should fail (cannot-verify is not a pass)"; exit 1
fi
printf '%s\n' "$out" | grep -qi 'PyYAML' || { echo "FAIL should name PyYAML: $out"; exit 1; }
if printf '%s\n' "$out" | grep -qi 'Traceback'; then
  echo "FAIL should not dump a traceback: $out"; exit 1
fi

# 10. The 10.9-portability lint runs as part of this gate, so every consumer gets it from the @v1 they
# already pin. Asserted HERE and not only in shell-portability-test.sh because the wiring is the part
# that can rot: check-shell-portability.sh could keep passing its own tests while this gate quietly
# stopped calling it, and nothing would go red.
mkrepo "$work/p1"
printf '#!/bin/sh\nd="$(mktemp -d)"\n' > "$work/p1/tool.sh"  # portability-ok: fixture must contain the violation
(cd "$work/p1" && git add -A) >/dev/null 2>&1
if out="$(cd "$work/p1" && sh "$S" 2>&1)"; then echo "FAIL a 10.9-unportable script should fail the gate"; exit 1; fi
printf '%s\n' "$out" | grep -q 'tool.sh:2' || { echo "FAIL should name file:line: $out"; exit 1; }

# 9. Every build ingredient must be able to auto-update. An ingredient nobody tracks is one that
# silently goes stale: swift-runtime's swift-toolchain pin sat at 6.3.3-mavericks.1 while that repo
# shipped .3, because updating it meant a human fetching and pasting two SHA256s. Wiring a Renovate
# customManager is the doctrine; a genuine exception (no datasource exists at all) must SAY so.
mkrepo "$work/r1"
printf '# Build ingredients\n\n| I | Pinned in | Renovate | On a bump |\n|---|---|---|---|\n| Go | `x` | ✅ github-releases | repackage |\n' \
  > "$work/r1/INGREDIENTS.md"
(cd "$work/r1" && sh "$S" >/dev/null) || { echo "FAIL tracked ingredient should pass"; exit 1; }

# an ingredient marked untracked fails, and the message points at the fix
mkrepo "$work/r2"
printf '# Build ingredients\n\n| I | Pinned in | Renovate | On a bump |\n|---|---|---|---|\n| Swift | `build.sh` | ❌ untracked | manual |\n' \
  > "$work/r2/INGREDIENTS.md"
if out="$(cd "$work/r2" && sh "$S" 2>&1)"; then echo "FAIL untracked ingredient should fail"; exit 1; fi
printf '%s\n' "$out" | grep -qi 'customManager\|renovate' || { echo "FAIL should name the fix: $out"; exit 1; }

# ...but a genuinely UNTRACKABLE input (no datasource exists -- golang's CA bundle) is allowed when
# it says so. The rule is "wire it or explain why you cannot", not "never write ❌".
mkrepo "$work/r3"
printf '# Build ingredients\n\n| I | Pinned in | Renovate | On a bump |\n|---|---|---|---|\n| CA bundle | `vendor/cacert.pem` | ❌ **untrackable — manual refresh** (see below) | watched path |\n' \
  > "$work/r3/INGREDIENTS.md"
(cd "$work/r3" && sh "$S" >/dev/null) || { echo "FAIL declared-untrackable should pass"; exit 1; }

# 11. A release shipping a new upstream links upstream's notes: the repo commits the hook that says
# where, or says in INGREDIENTS.md why there is nothing to link.
mkrepo "$work/u1"; (cd "$work/u1" && git rm -q --cached build/upstream-release-notes-url.sh && rm -r build)
if out="$(cd "$work/u1" && sh "$S" 2>&1)"; then echo "FAIL no hook and no reason should fail"; exit 1; fi
printf '%s\n' "$out" | grep -q 'upstream-release-notes-url.sh' || { echo "FAIL should name the hook: $out"; exit 1; }
printf '%s\n' "$out" | grep -q 'No upstream release notes:' || { echo "FAIL should name the declaration: $out"; exit 1; }
# the declaration, with a reason, is the other way to comply (a self-upstream repo; a bundle)
printf '# Build ingredients\n\nNo upstream release notes: this repo is its own upstream.\n' > "$work/u1/INGREDIENTS.md"
(cd "$work/u1" && sh "$S" >/dev/null) || { echo "FAIL declared no-upstream-notes should pass"; exit 1; }
# ...but an empty reason is not a reason
printf '# Build ingredients\n\nNo upstream release notes:\n' > "$work/u1/INGREDIENTS.md"
if (cd "$work/u1" && sh "$S" >/dev/null 2>&1); then echo "FAIL a reasonless declaration should fail"; exit 1; fi
# the swift repos keep their scripts, and so the hook, in scripts/
mkrepo "$work/u2"; (cd "$work/u2" && mkdir scripts && git mv build/upstream-release-notes-url.sh scripts/)
[ -f "$work/u2/scripts/upstream-release-notes-url.sh" ] && [ ! -e "$work/u2/build/upstream-release-notes-url.sh" ] \
  || { echo "FAIL fixture: hook did not move to scripts/"; exit 1; }
(cd "$work/u2" && sh "$S" >/dev/null) || { echo "FAIL a hook in scripts/ should pass"; exit 1; }
# a hook that exists but is not committed is the trap: a .gitignore'd build/ drops it without a word
# (macports-legacy-support ignores build/ wholesale), and CI's fresh checkout never sees it
mkrepo "$work/u3"; (cd "$work/u3" && git rm -q --cached build/upstream-release-notes-url.sh && printf 'build/\n' >> .gitignore)
if out="$(cd "$work/u3" && sh "$S" 2>&1)"; then echo "FAIL an uncommitted hook should fail"; exit 1; fi
printf '%s\n' "$out" | grep -qi 'not committed' || { echo "FAIL should say it is not committed: $out"; exit 1; }

# 12. A workflow that signs must call scan-for-key.yml -- publish-release.yml refuses a signed
# release without its record, and a missing job should fail a PR here, not a release there.
mkrepo "$work/k"
printf '      - run: sh "$SHIPYARD_SCRIPTS/sign_and_appcast.sh" --pkg dist/x.pkg > dist/appcast.xml\n' \
  >> "$work/k/.github/workflows/release.yml"
(cd "$work/k" && git add -A) >/dev/null 2>&1
if out="$(cd "$work/k" && sh "$S" 2>&1)"; then echo "FAIL a signing workflow with no scan job should fail"; exit 1; fi
printf '%s\n' "$out" | grep -q 'scan-for-key.yml' || { echo "FAIL should name scan-for-key.yml: $out"; exit 1; }
cat >> "$work/k/.github/workflows/release.yml" <<'YML'
  scan:
    needs: [build]
    if: always()
    uses: ModernMavericks/shipyard/.github/workflows/scan-for-key.yml@v1
    with: { artifact: dist }
YML
(cd "$work/k" && git add -A) >/dev/null 2>&1
(cd "$work/k" && sh "$S" >/dev/null) || { echo "FAIL a signing workflow with a scan job should pass"; exit 1; }

# 13. A pin on a -mavericks.N release must be read with versioning that COMPARES N. Renovate's default
# coerces the suffix away, so .1 and .4 compare equal and the bot proposes nothing: swift-runtime's
# swift-toolchain pin sat at 6.3.3-mavericks.1 while .4 shipped, with a manager wired and green.
MMVER='regex:^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)-mavericks\.(?<build>\d+)$'
mkrepo "$work/mv"   # swift-runtime's shape: an inline pin in a shared file, default versioning
printf 'TOOLCHAIN_REF="6.3.3-mavericks.1"\n' > "$work/mv/build.sh"
printf '%s\n' '{"extends":["github>ModernMavericks/shipyard"],"customManagers":[{"customType":"regex","managerFilePatterns":["/^build\\.sh$/"],"matchStrings":["TOOLCHAIN_REF=\"(?<currentValue>[^\"]+)\""],"depNameTemplate":"ModernMavericks/swift-toolchain","datasourceTemplate":"github-releases"}]}' \
  > "$work/mv/.github/renovate.json"
(cd "$work/mv" && git add -A) >/dev/null 2>&1
if out="$(cd "$work/mv" && sh "$S" 2>&1)"; then echo "FAIL a -mavericks.N pin with default versioning should fail"; exit 1; fi
printf '%s\n' "$out" | grep -q 'ModernMavericks/swift-toolchain' || { echo "FAIL should name the dep: $out"; exit 1; }
printf '%s\n' "$out" | grep -q 'mavericks' || { echo "FAIL should name the -mavericks.N versioning: $out"; exit 1; }
# ...with the family's versioning regex (container-tools/tailscale tracking golang), it passes
python3 - "$work/mv/.github/renovate.json" "$MMVER" <<'PY'
import json, sys
p = sys.argv[1]; c = json.load(open(p))
c["customManagers"][0]["versioningTemplate"] = sys.argv[2]
json.dump(c, open(p, "w"))
PY
(cd "$work/mv" && git add -A) >/dev/null 2>&1
(cd "$work/mv" && sh "$S" >/dev/null) || { echo "FAIL a -mavericks.N pin with the family versioning should pass"; exit 1; }
# ...but a regex that matches the version without capturing N is the same bug, spelled differently
mkrepo "$work/mv2"
printf '6.3.3-mavericks.1\n' > "$work/mv2/components-version"
printf '%s\n' '{"extends":["github>ModernMavericks/shipyard"],"customManagers":[{"customType":"regex","managerFilePatterns":["/^components-version$/"],"matchStrings":["^(?<currentValue>.+?)\\s*$"],"depNameTemplate":"x","datasourceTemplate":"github-releases","versioningTemplate":"regex:^(?<major>\\d+)\\.(?<minor>\\d+)\\.(?<patch>\\d+)"}]}' \
  > "$work/mv2/.github/renovate.json"
(cd "$work/mv2" && git add -A) >/dev/null 2>&1
if (cd "$work/mv2" && sh "$S" >/dev/null 2>&1); then echo "FAIL versioning that ignores N should fail"; exit 1; fi
# ...and a pin that is NOT a -mavericks.N release needs nothing (openssh's own upstream, tag form)
mkrepo "$work/mv3"
printf 'V_9_9_P2\n' > "$work/mv3/components-version"
printf '%s\n' '{"extends":["github>ModernMavericks/shipyard"],"customManagers":[{"customType":"regex","managerFilePatterns":["/^components-version$/"],"matchStrings":["^(?<currentValue>V_[0-9_P]+)\\s*$"],"depNameTemplate":"openssh/openssh-portable","datasourceTemplate":"github-tags"}]}' \
  > "$work/mv3/.github/renovate.json"
(cd "$work/mv3" && git add -A) >/dev/null 2>&1
(cd "$work/mv3" && sh "$S" >/dev/null) || { echo "FAIL a non-mavericks pin should pass"; exit 1; }

# A failing run must NOT also print "ok". The success line used to sit mid-script, so checks appended
# after it (7, 8, 9) printed "check-family-conventions: ok" and THEN failed -- the exact "output says
# it passed while it did not" shape these gates exist to prevent.
mkrepo "$work/ok2"
printf '# Build ingredients\n\n| I | P | Renovate | On a bump |\n|---|---|---|---|\n| X | `y` | ❌ untracked | manual |\n' \
  > "$work/ok2/INGREDIENTS.md"
out="$(cd "$work/ok2" && sh "$S" 2>&1 || true)"
printf '%s\n' "$out" | grep -q 'check-family-conventions: ok' \
  && { echo "FAIL a failing run printed ok: $out"; exit 1; }

echo "PASS: check-family-conventions"
