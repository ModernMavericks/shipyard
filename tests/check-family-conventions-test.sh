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
  group: release-${{ github.ref }}
  cancel-in-progress: false
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

# 1b. concurrency that keys on github.run_id makes every run its own group, so local_release dispatches
# don't serialize and two can cut the same -mavericks.(N+1) tag -> must fail.
mkrepo "$work/cr"
python3 - "$work/cr/.github/workflows/release.yml" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace("  group: release-${{ github.ref }}",
            "  group: release-${{ github.event_name == 'workflow_dispatch' && github.run_id || github.ref }}")
open(p,'w').write(s)
PY
if (cd "$work/cr" && sh "$S" >/dev/null 2>&1); then echo "FAIL run_id concurrency group should fail"; exit 1; fi
(cd "$work/cr" && sh "$S" 2>&1 | grep -qiE 'run_id|serial') || { echo "FAIL should name the run_id/serialize problem"; exit 1; }

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
