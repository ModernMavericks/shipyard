#!/bin/sh
# publish-release.yml must validate the body it is about to publish. The gate checks a repo's wiring
# on its PR (check-family-conventions.sh clause 14); this is the one place EVERY release passes
# through -- a hand-tagged release, a re-dispatch of an old build, a repo that never had the gate --
# so it is the only check a body regression cannot route around. It must also run in the right place:
# after release-assets.sh proves dist/$NOTES exists and is non-empty (a worse error otherwise), and
# before the first publish attempt (a validation that runs after publishing checks nothing).
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
w="$here/../.github/workflows/publish-release.yml"

python3 - "$w" <<'PY'
import re, sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
steps = []
for job in wf["jobs"].values():
    steps += job.get("steps") or []

def fail(msg):
    print("FAIL: " + msg); sys.exit(1)

# Strip whole-line comments and join backslash continuations before matching: a call left inside a
# comment (or behind `if: false` / the equivalent `if: ${{ false }}` expression form) must not read as
# "wired in" -- Task 4's fixture passed for the wrong reason once already, because the check it was
# supposed to prove had silently stopped running.
def step_cmds(step):
    lines = [l for l in (step.get("run") or "").splitlines() if not l.lstrip().startswith("#")]
    joined = re.sub(r"\\\s*\n\s*", " ", "\n".join(lines))
    return [" ".join(l.split()) for l in joined.splitlines() if l.strip()]

assets = [s for s in steps if s.get("id") == "assets"]
if not assets:
    fail("no step with id 'assets' -- the release-assets.sh step was renamed or removed")
a = assets[0]
if_norm = re.sub(r"\s+", "", str(a.get("if", ""))).lower()
if if_norm in ("false", "${{false}}"):
    fail("the assets step is disabled (if: false)")

cmds = step_cmds(a)

# The literal path, not just the script's basename: publish-release.yml checks out ONLY shipyard, into
# .shipyard/ (the product repo itself is never checked out here) -- "scripts/check-release-notes.sh"
# with no .shipyard/ prefix does not exist on this runner and exits 127, stranding every release in the
# family. Task 4 already learned this lesson once: only literal paths compare.
ra = [i for i, c in enumerate(cmds) if ".shipyard/scripts/release-assets.sh" in c]
if not ra:
    fail("the assets step no longer calls .shipyard/scripts/release-assets.sh")

# The call, and nothing chained onto it. A first cut at this check enumerated specific silencers
# (|| true, || :, ; true, continue-on-error: true) -- and a re-review walked straight past that list:
# || echo skipped, || exit 0 (which also skips the checksum verification below, by exiting the whole
# run: block), || logger x, && true, a pipe into cat, all leave a disabled gate looking green. Rather
# than keep enumerating spellings, require the STRUCTURE: the line that calls check-release-notes.sh
# must be the whole command -- nothing before it, nothing chained after it with ||, &&, ;, or a pipe.
# Any fallback of any spelling, thought of or not, then fails this instead of passing it.
call_re = re.compile(r'sh \.shipyard/scripts/check-release-notes\.sh "?dist/\$NOTES"? "?\$VERSION"?')
crn = [i for i, c in enumerate(cmds) if call_re.fullmatch(c)]
if not crn:
    decorated = [c for c in cmds if call_re.search(c)]
    if decorated:
        fail("check-release-notes.sh is called, but not as a standalone command -- "
             "something is chained onto it (||, &&, ;, a pipe, ...), so a refused body can still ship: %r" % decorated[0])
    fail('the assets step does not call .shipyard/scripts/check-release-notes.sh on "dist/$NOTES" "$VERSION" -- '
         "a copied notes file under a new tag would pass every other check and announce its predecessor")

# A structurally-clean call line can still run under a disabled errexit set earlier in the SAME step --
# `set +e` neuters the call without touching the call's own line at all, so the line check above cannot
# see it. Nothing between the step's start and the call may turn -e off.
if any(re.match(r"^set\b", c) and "+e" in c for c in cmds[:crn[0]]):
    fail("the assets step disables errexit (set +e) before calling check-release-notes.sh -- "
         "its failure would then not stop the step, so a refused body can still ship")

if str(a.get("continue-on-error", "")).strip().lower() == "true":
    fail("the assets step is continue-on-error: true -- check-release-notes.sh failing would not fail the job")

if crn[0] < ra[0]:
    fail("check-release-notes.sh runs before release-assets.sh -- validating a file not yet proven to exist")

sums = [i for i, c in enumerate(cmds) if "SHA256SUMS" in c]
if sums and crn[0] > min(sums):
    fail("check-release-notes.sh runs after the checksum block -- validate the body before spending work checksumming it")

env = a.get("env") or {}
if "inputs.version" not in str(env.get("VERSION", "")):
    fail("the assets step's env has no VERSION set to inputs.version -- check-release-notes.sh has nothing to check the body against")

# ...and before the FIRST publish attempt, or it validates a body that may already have shipped.
gi = steps.index(a)
pubs = [i for i, s in enumerate(steps) if "action-gh-release" in (s.get("uses") or "")]
if not pubs:
    fail("no step publishes with softprops/action-gh-release")
if gi > pubs[0]:
    fail("the assets step runs after the first publish attempt")

print("ok: check-release-notes.sh runs on dist/$NOTES against $VERSION, after release-assets.sh, "
      "before the checksum block, and before the first publish attempt")
PY

# The behaviour itself, against the real script, on the two bodies that mattered historically: a
# hand-rolled body from a repo that never adopted the shared generator, and an empty body (tailscale
# published one on EVERY release, forever, before Plan 1 closed that hole).
S="$here/../scripts/check-release-notes.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/pns.XXXXXX")"
trap 'rm -rf "$T"' EXIT

printf '## %s\n\nAutomated release.\n' 9.9p2-mavericks.6 > "$T/hand.md"
if sh "$S" "$T/hand.md" 9.9p2-mavericks.6 >/dev/null 2>&1; then
  echo "FAIL: a hand-rolled body (no '### What changed') must not pass"; exit 1
fi
echo "ok: a hand-rolled body is refused"

: > "$T/empty.md"
if sh "$S" "$T/empty.md" 9.9p2-mavericks.6 >/dev/null 2>&1; then
  echo "FAIL: an empty body must not pass"; exit 1
fi
echo "ok: an empty body is refused"

echo "PASS: publish-notes-shape"
