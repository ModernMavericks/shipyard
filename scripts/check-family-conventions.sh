#!/bin/sh
# Gate: does this repo still look like its siblings? A convention that is not checked is a convention
# that drifts -- seven repos started from one shape and diverged into two publishers, four concurrency
# policies, three repos not running their own tests, and 11 copies of one shell incantation.
#
# Fails loudly and names the fix. A repo with no release.yml (shipyard itself) has nothing to check.
#   usage: check-family-conventions.sh
set -eu
SELF="$(cd "$(dirname "$0")" && pwd)"   # siblings live here (.shipyard/scripts in a consumer)
REL=".github/workflows/release.yml"
[ -f "$REL" ] || { echo "check-family-conventions: no $REL — not a product repo, nothing to check"; exit 0; }

# Everything under .github/workflows counts as "CI": some repos run their tests from ci.yml, not
# release.yml, and either is fine as long as something does.
CI_FILES="$(ls .github/workflows/*.yml 2>/dev/null || true)"
ci_mentions() {  # $1 = pattern. -e so a pattern starting with '-' (--notes-file) is not read as a flag.
  [ -n "$CI_FILES" ] || return 1
  # shellcheck disable=SC2086  # CI_FILES is a deliberate word-split list of paths
  grep -lq -e "$1" $CI_FILES 2>/dev/null
}

status=0
fail() { echo "check-family-conventions: $1" >&2; echo "    fix: $2" >&2; status=1; }

# 1. Concurrency: two publishes racing the same tag is a corrupt release, not a flaky build.
grep -q '^concurrency:' "$REL" \
  || fail "$REL declares no concurrency: — two publishes can race the same tag" \
          "add a concurrency: block with cancel-in-progress: false"

# 1b. ...and the group must DISTINGUISH publishing runs from build feedback. `cancel-in-progress:
# false` protects the run that is EXECUTING, not one that is QUEUED: GitHub keeps only the newest
# pending run in a group and cancels the rest. With one group for every event, a queued dispatch is
# evicted by the next arrival, its tag is never minted, and nothing goes red -- the release simply
# does not exist. Observed 2026-09-09 in mavericks-golang, where 13 seconds separated the two.
#
# So push (and pull_request) share a per-ref group and SUPERSEDE -- only the newest commit's feedback
# is worth having -- while workflow_dispatch and tags get a group of their own and are cancelled by
# nothing. This replaces the old serialization lock; two dispatches can now compute the same
# -mavericks.(N+1), and publish-release.yml's "Refuse an already-taken tag" step is what catches it.
if awk '/^concurrency:/{f=1;next} /^[^[:space:]#]/{f=0} f' "$REL" | grep -q 'github\.event_name'; then
  :
else
  fail "$REL uses ONE concurrency group for every event — a queued publish is evicted by the next run and its release silently never happens" \
       "key the group on the event: group: release-\${{ github.event_name == 'push' && github.ref || github.sha }} with cancel-in-progress: \${{ github.event_name == 'push' }}"
fi

# 2. Tests that exist must run. Hand-enumeration is how they stop running.
if [ -d tests ] && [ -n "$(ls tests/*.sh tests/*.bats 2>/dev/null || true)" ]; then
  ci_mentions 'run-repo-tests' || ci_mentions 'ctest' \
    || fail "tests/ has test files but no workflow runs them" \
            "add: sh \"\$SHIPYARD_SCRIPTS/run-repo-tests.sh\"   (or ctest, where that is the driver)"
fi

# 3. Every product bakes in inputs; say what they are and how each is tracked.
[ -f INGREDIENTS.md ] \
  || fail "no INGREDIENTS.md — the repo's build inputs are undocumented" \
          "list each input, where it is pinned, its Renovate status, and what a bump does"

# 4. A key restating the preset's own value is redundant: it silently stops tracking the preset the day
#    the preset changes. The SAME key with a DIFFERENT value is a deliberate override and stays legal --
#    a repo with no build to gate opts back into blind automerge with ignoreTests:true.
if [ -f .github/renovate.json ]; then
  # preset values, kept next to the preset that sets them (default.json)
  for pair in 'ignoreTests:false'; do
    k="${pair%%:*}"; presetval="${pair#*:}"
    grep -q "\"$k\"[[:space:]]*:[[:space:]]*$presetval" .github/renovate.json \
      && fail "renovate.json sets \"$k\": $presetval, which is exactly what the shared preset sets" \
              "delete the key (the preset owns it); keep it only to override with a different value"
  done
fi

# 4b. The family default is ship-if-green: patch, minor and major automerge once the build passes, and
#     breakage is fixed forward in a -mavericks.N+1 release. A repo restricts automerge only where a bad
#     bump would BUILD FINE AND BE WRONG -- the case a green build cannot catch (swift-toolchain: a
#     minor Swift bump needs LLVM_BRANCH to follow, which no regex can infer). Write that reason down,
#     or the exception is indistinguishable from drift.
if [ -f .github/renovate.json ]; then
  python3 - .github/renovate.json <<'PY' || status=1
import json, sys
bad = []
for r in json.load(open(sys.argv[1])).get('packageRules', []):
    if 'automerge' in r and not (r.get('description') or '').strip():
        bad.append(r.get('matchDepNames') or r.get('matchPackageNames') or '(unnamed rule)')
if bad:
    print("check-family-conventions: automerge exception with no description: %s" % bad, file=sys.stderr)
    print("    fix: say why a green build is not enough here (what would build fine and be wrong),", file=sys.stderr)
    print("         or drop the rule and take the family default (ship-if-green)", file=sys.stderr)
    sys.exit(1)
PY
fi

# 5. Notes must reach readers. An empty Release body ships without anyone noticing (tailscale did,
#    for every release, including hand-tagged ones that had a committed notes file).
# publish-release.yml is the strongest evidence: it OWNS the body and fails on an empty one. The other
# three only show that some step was handed notes -- note that --notes-file also matches a Sparkle
# appcast call, which is not the Release body, so this check is weaker than it reads for repos that
# have not adopted the shared publisher yet.
ci_mentions 'publish-release.yml' || ci_mentions '--notes-file' || ci_mentions 'body_path' \
  || ci_mentions '--generate-notes' \
  || fail "the release publishes no notes body" \
          "publish via publish-release.yml@v1, or pass --notes-file / body_path when creating the release"

# 7. VERSION is DERIVED, not committed. The shipped state lives in tags; a committed VERSION is a
# second answer to "what version is this?" and it drifts -- container-tools built -mavericks.14 from a
# committed file that still said .2, which also made its tag path (tag must equal VERSION)
# unsatisfiable. An UNTRACKED VERSION in the tree is fine and expected: it is a build product.
if git rev-parse --git-dir >/dev/null 2>&1; then
  if git ls-files --error-unmatch VERSION >/dev/null 2>&1; then
    fail "VERSION is committed — it is a build product, and the committed copy goes stale while tags move on" \
         "git rm --cached VERSION; add /VERSION to .gitignore; commit UPSTREAM_VERSION instead"
  fi
else
  # Not a checkout: the gate cannot see what is tracked. Say so rather than pass silently.
  echo "check-family-conventions: not a git checkout — cannot check whether VERSION is committed" >&2
  status=1
fi

# ...and something must be able to SUPPLY the upstream version: a committed UPSTREAM_VERSION, one per
# line for a repo shipping parallel lines (golang), or a script that derives it from the pin (ed25519
# reads the pinned commit's date; tailscale reads upstream's own VERSION.txt).
if [ ! -f UPSTREAM_VERSION ] \
   && [ -z "$(ls lines/*/UPSTREAM_VERSION 2>/dev/null || true)" ] \
   && [ -z "$(ls build/derive-upstream-version.sh scripts/derive-upstream-version.sh 2>/dev/null || true)" ]; then
  fail "no UPSTREAM_VERSION and nothing to derive one — the version cannot be computed" \
       "commit UPSTREAM_VERSION (bare x.y.z or a date), or add build/derive-upstream-version.sh"
fi

# 7b. Parallel lines (golang Go-minors, nodejs Node-majors): each lines/<id>/UPSTREAM_VERSION is a
# separate product track and MUST have its OWN capped Renovate manager. Uncapped, Renovate walks the
# line onto the next major/minor it was never built for; unmanaged, it goes stale silently; a single
# manager spanning lines cannot cap each (one allowedVersions can't fit two lines). "A line is a
# product" — see the conventions skill.
if [ -n "$(ls lines/*/UPSTREAM_VERSION 2>/dev/null || true)" ]; then
  if [ ! -f .github/renovate.json ]; then
    fail "lines/ ships parallel tracks but there is no .github/renovate.json to track them" \
         "add one capped customManager per lines/<id>/UPSTREAM_VERSION (allowedVersions cap)"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - .github/renovate.json <<'PY' || status=1
import json, sys, re, glob, os
cfg = json.load(open(sys.argv[1]))
mgrs = cfg.get("customManagers", [])
rules = cfg.get("packageRules", [])
lines = sorted(os.path.basename(os.path.dirname(p)) for p in glob.glob("lines/*/UPSTREAM_VERSION"))

def path_matches(mgr, path):
    for p in mgr.get("managerFilePatterns", []) or mgr.get("fileMatch", []) or []:
        rx = p[1:-1] if len(p) >= 2 and p[0] == "/" and p.endswith("/") else p
        try:
            if re.search(rx, path):
                return True
        except re.error:
            if p.strip("/") in path:
                return True
    return False

def is_capped(mgr):
    dep = mgr.get("depNameTemplate") or mgr.get("packageNameTemplate") or ""
    if mgr.get("allowedVersions"):
        return True
    for r in rules:
        names = (r.get("matchDepNames") or []) + (r.get("matchPackageNames") or [])
        if dep and dep in names and r.get("allowedVersions"):
            return True
    return False

rc = 0
def bad(msg, fix):
    global rc
    print("check-family-conventions: " + msg, file=sys.stderr)
    print("    fix: " + fix, file=sys.stderr)
    rc = 1

for ln in lines:
    path = "lines/%s/UPSTREAM_VERSION" % ln
    owning = [m for m in mgrs if path_matches(m, path)]
    if not owning:
        bad("lines/%s/UPSTREAM_VERSION has no Renovate customManager — the line goes stale silently" % ln,
            "add a customManager on /^lines/%s/UPSTREAM_VERSION$/ with an allowedVersions cap" % ln)
        continue
    # A manager that also matches ANOTHER line's file cannot cap each line separately.
    spanning = [m for m in owning if sum(1 for o in lines if path_matches(m, "lines/%s/UPSTREAM_VERSION" % o)) > 1]
    if spanning:
        bad("a Renovate manager spans multiple lines/ tracks — one allowedVersions cannot cap each line",
            "give lines/%s/UPSTREAM_VERSION its own manager anchored to just that path (/^lines/%s/UPSTREAM_VERSION$/)" % (ln, ln))
        continue
    if not any(is_capped(m) for m in owning):
        bad("lines/%s/UPSTREAM_VERSION has a Renovate manager but no allowedVersions cap — Renovate will walk it onto the next line" % ln,
            "cap it (e.g. a packageRule matchDepNames:[<dep>] allowedVersions:\"<%s\")" % ln)
sys.exit(rc)
PY
  else
    echo "check-family-conventions: python3 absent — cannot verify per-line Renovate caps (lines/ present)" >&2
    status=1
  fi
fi

# 7c. The version wrappers live in COMMITTED build/*.sh (build/version.sh, msc.sh, lib.sh, …); a
# too-broad .gitignore (`build*/`, `build/`) silently ignores them. `git add` skips them without a
# word, everything works locally, and only CI's fresh checkout fails — "sh: build/version.sh: No such
# file or directory" — far from the cause. `git check-ignore` evaluates the path against .gitignore
# regardless of whether the file is present, so this fires even from a checkout that already lost it.
# Only for repos that actually use the wrappers (a workflow references build/version.sh, or it exists).
if git rev-parse --git-dir >/dev/null 2>&1; then
  if ci_mentions 'build/version.sh' || [ -e build/version.sh ]; then
    if git check-ignore -q build/version.sh 2>/dev/null; then
      fail "build/version.sh is git-ignored — a too-broad .gitignore pattern (e.g. build*/) drops the committed version wrappers; local passes, CI's fresh checkout fails 'no build/version.sh'" \
           "ignore only build OUTPUT dirs (/_build/, build-*/, build/work/) — never build/ itself"
    fi
  fi
fi

# 8. Every workflow must PARSE, with duplicate keys rejected. A second `with:` on one step is legal
# YAML -- last key wins, and every ordinary parser accepts it -- but GitHub refuses to run the
# workflow: the run appears named after the file path, "likely failed because of a workflow file
# issue", with no step logs to read. Nothing else in CI can catch this, because CI never starts.
if [ -n "$CI_FILES" ] && command -v python3 >/dev/null 2>&1; then
  # PyYAML is the checker's OWN dependency, and GitHub's macOS runner python3 ships without it.
  # Probe first: otherwise the parse below dies on `import yaml` and reports a bare
  # ModuleNotFoundError traceback against a repo that is perfectly compliant -- which is how this
  # gate red-lit every run for a month without once naming what to install. Cannot-verify still
  # FAILS, the same rule as the per-line Renovate check above: a gate that passes when it did not
  # run is the rot it exists to prevent. shipyard's install action provisions PyYAML, so CI never
  # lands here.
  if ! python3 -c 'import yaml' >/dev/null 2>&1; then
    fail "python3 has no PyYAML — cannot verify that the workflows parse, so a duplicate key would ship unseen" \
         "install it (python3 -m pip install pyyaml); shipyard's .github/actions/install does this for CI"
  else
  # shellcheck disable=SC2086  # deliberate word-split list of paths
  python3 - $CI_FILES <<'PYEOF' || status=1
import sys, yaml

class Strict(yaml.SafeLoader):
    pass

def no_duplicate_keys(loader, node, deep=False):
    seen = set()
    for key_node, _ in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in seen:
            raise ValueError("duplicate key %r on line %d" % (key, key_node.start_mark.line + 1))
        seen.add(key)
    return yaml.SafeLoader.construct_mapping(loader, node, deep)

Strict.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, no_duplicate_keys)

rc = 0
for path in sys.argv[1:]:
    try:
        with open(path) as fh:
            yaml.load(fh, Strict)
    except Exception as exc:
        sys.stderr.write("check-family-conventions: %s does not parse: %s\n" % (path, exc))
        sys.stderr.write("    fix: GitHub rejects the whole workflow -- it never runs, so no other gate sees this\n")
        rc = 1
sys.exit(rc)
PYEOF
  fi
fi

# 9. Every build ingredient must be able to AUTO-UPDATE. An ingredient nobody tracks goes stale
# silently: swift-runtime's swift-toolchain pin sat at 6.3.3-mavericks.1 while that repo shipped .3,
# because moving it meant a human fetching and pasting two SHA256s. Wiring a Renovate customManager is
# the doctrine -- and where a pinned hash is what blocks the bot, verify against the upstream's own
# published SHA256SUMS instead, which vouches for bytes nobody has seen yet.
#
# A genuine exception (no datasource exists at all -- golang's CA bundle) is allowed, but must SAY
# "untrackable" rather than leaving a bare ❌ that reads as an oversight.
if [ -f INGREDIENTS.md ]; then
  while IFS= read -r line; do
    case "$line" in
      *❌*)
        case "$line" in
          *[Uu]ntrackable*) : ;;   # declared, with a reason nearby
          *) fail "INGREDIENTS.md marks an ingredient as not auto-updating: $(printf '%s' "$line" | cut -c1-60)..." \
                  "wire a Renovate customManager for it (a pinned hash that blocks the bot can verify against upstream's published SHA256SUMS instead), or mark it **untrackable** and say why" ;;
        esac
        ;;
    esac
  done < INGREDIENTS.md
fi

# 10. No shell construct the 10.9 base system lacks. These are invisible to CI by construction: they
# work on the runner and fail on the platform every repo here targets, so the machine that would
# catch them is the one machine CI never uses. shipyard shipped two of them (`sort -V`, a bare
# `mktemp -d`) and reached all seven repos through @v1 before anyone noticed -- one of them turning
# release notes silently empty rather than erroring.
#
# The rules live in check-shell-portability.sh, which this gate and shipyard's own test suite both
# call, so the family's rule and shipyard's rule cannot drift apart. It reports its own file:line and
# fix, so its output is passed through rather than restated.
if [ -f "$SELF/check-shell-portability.sh" ]; then
  sh "$SELF/check-shell-portability.sh" >/dev/null || status=1
else
  fail "cannot find check-shell-portability.sh next to this gate — the shipyard checkout is incomplete" \
       "check out the whole repo (family-conventions.yml does), not just this one script"
fi

# LAST, after every check: this line used to sit mid-script, so checks appended below it printed
# "ok" and then failed in the same run.
[ "$status" -eq 0 ] && echo "check-family-conventions: ok"

exit "$status"
