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
          "add a concurrency: block -- group keyed on github.run_id, cancel-in-progress naming pull_request"

# 1b. ...and it must put a run that CAN PUBLISH alone in its group, cancellable by nothing.
#
# `cancel-in-progress: false` is not that guarantee and never was: it protects the run that is
# EXECUTING, not one that is QUEUED. GitHub keeps only the newest pending run in a group and cancels
# the rest. So the shape this family ran until 2026-09-09 -- every dispatch herded into one shared
# literal group, sold as a version-bump lock -- discarded releases silently: the tag is never minted,
# nothing goes red, the release simply does not exist. Observed in mavericks-golang, 13 seconds
# between the two runs, and reproduced on demand with a throwaway probe: two same-SHA dispatches
# merely queue, and the THIRD cancels the queued second.
#
# Hence two demands, not one. The GROUP must be keyed on github.run_id, so a publishing run is alone
# in it -- never queued behind a sibling, so never evictable. And CANCEL-IN-PROGRESS must be the
# pull_request test, so the only thing that ever supersedes is PR feedback, where a force-push
# replacing its predecessor is exactly what you want.
#
# Branch pushes sit on the never-cancelled side too, because in eight of the thirteen product repos a
# push to main can auto-cut a release, and concurrency is resolved when a run is QUEUED -- before the
# ver step decides whether this one publishes -- so cancelling the run would cancel the publish job
# with it. This replaces the old lock; two dispatches can now compute the same -mavericks.(N+1), and
# publish-release.yml's "Refuse an already-taken tag" step is what catches it.
CONC="$(awk '/^concurrency:/{f=1;next} /^[^[:space:]#]/{f=0} f' "$REL")"
GROUP="$(printf '%s\n' "$CONC" | awk '/^[[:space:]]*group:/{f=1;print;next} /^[[:space:]]*cancel-in-progress:/{f=0} f')"
CANCEL="$(printf '%s\n' "$CONC" | awk '/^[[:space:]]*cancel-in-progress:/{f=1;print;next} /^[[:space:]]*group:/{f=0} f')"

printf '%s\n' "$GROUP" | grep -q 'github\.run_id' \
  || fail "$REL concurrency group is shared between runs that can publish — a queued one is evicted by the next arrival and its release silently never happens" \
          "key the group per run: group: release-\${{ github.event_name == 'pull_request' && github.ref || github.run_id }}"

printf '%s\n' "$CANCEL" | grep -q 'pull_request' \
  || fail "$REL can cancel a run that publishes — cancel-in-progress must name pull_request, the only event that may supersede" \
          "cancel-in-progress: \${{ github.event_name == 'pull_request' }}"

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

# 7d. The mirror of 7c: a build OUTPUT dir that is NOT ignored. tailscale configured the Sparkle
# updater with `cmake -S updater -B build/updater` -- a path the shared presets do not name -- so
# nothing connected it to .gitignore, and 7.4MB of CMake output sat in the checkout untracked AND
# unignored, one `git add -A` from being committed. Its CMakeCache.txt was still resolving
# MavericksSharedCMake_DIR months after the rename, which is what a stale cache does: it keeps working
# against a package that no longer exists under that name, until it doesn't.
#
# The family will not agree on one spelling and does not need to -- ten of the fifteen repos write
# their ignores differently and every one of them is correct for its own layout. So ask the REPO where
# it writes: every `cmake ... -B <dir>` in its workflows and committed shell, plus every binaryDir a
# committed CMakePresets.json names. A path that already leaves the tree (absolute, or built from a
# variable like $RUNNER_TEMP) needs no ignore -- that is the point of leaving.
if git rev-parse --git-dir >/dev/null 2>&1; then
  # cmake's -B specifically: a bare -B also means "lines of context" to grep, and reading that as a
  # build directory would invent failures out of `grep -B 3`.
  # Every stage here has to be failure-tolerant: this runs under `set -e`, and a grep that simply
  # finds nothing exits 1. As the LAST command of a command substitution that would fail the
  # assignment and kill the whole gate with no output at all -- which is exactly what it did on the
  # first draft. Hence the `|| true` and the trailing `:`.
  #
  # `git ls-files` and not `find`: read only what the repo COMMITS. A find(1) sweep also reads build
  # output and the AppleDouble `._*.sh` files an NFS checkout collects -- in shipyard, 65 .sh against
  # 58 tracked. BSD sed aborts on their binary content ("RE error: illegal byte sequence"), and that
  # truncates the candidate stream mid-pipe, so the check silently stops looking and an unignored
  # build dir further down goes unreported. Tracked-only also drops the vendored .shipyard/ checkout
  # that family-conventions.yml unpacks inside the consumer's workspace -- an unfiltered sweep read
  # THIS file and reported the `cmake ... -B <dir>` in these very comments as the consumer's build
  # dir, reddening two repos within the hour it shipped.
  #
  # The other two filters stay, for prose inside files that ARE committed:
  #   - COMMENT lines are dropped. Prose that mentions a cmake command line is not a build.
  #   - the candidate must LOOK like a relative path, which throws out `<dir>`, a stray comma, and
  #     the regex fragment on the line below.
  bdirs="$(
    {
      [ -n "$CI_FILES" ] && cat $CI_FILES 2>/dev/null
      git ls-files -z '*.sh' 2>/dev/null | xargs -0 cat 2>/dev/null
      :
    } | sed -e 's/^[[:space:]]*#.*$//' \
      | grep -oE 'cmake[^;|&]*-B[[:space:]]*[^[:space:];|&)]+' \
      | sed -e 's/.*-B[[:space:]]*//' -e 's/^["'"'"']//' -e 's/["'"'"']$//' || true
    if [ -f CMakePresets.json ]; then
      sed -n 's/.*"binaryDir"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' CMakePresets.json
    fi
    :
  )"
  for d in $bdirs; do
    d="${d#\$\{sourceDir\}/}"          # presets say ${sourceDir}/build-native; we ask about build-native
    d="${d%/}"
    case "$d" in
      ''|/*|~*|*'$'*|*..*) continue ;; # out of tree, or a path we cannot resolve: not ours to demand
    esac
    # Must look like a relative path. Prose survives the comment filter when it is inline rather than
    # a whole comment line, and `<dir>` is not a directory.
    case "$d" in
      *[!A-Za-z0-9._/+-]*) continue ;;
    esac
    # Ask about "$d/", not "$d". A .gitignore pattern written `build/updater/` matches a DIRECTORY,
    # and git can only tell a nonexistent path is one if the query says so. Build output is exactly
    # the thing that does not exist in a fresh checkout, so querying without the slash would have
    # failed every correctly-ignored repo the moment this ran in CI.
    git check-ignore -q "$d/" 2>/dev/null && continue
    fail "$d is a build output directory this repo writes, but .gitignore does not cover it — one \`git add -A\` commits the build tree, and a stale CMakeCache keeps resolving a package that has been renamed away" \
         "add $d/ to .gitignore (any pattern that covers it; the family does not share one spelling)"
  done
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

# 11. A release that ships a NEW upstream links upstream's own notes: a -mavericks.1 exists to deliver
# someone else's changes, and naming the version does not say where to read them. shipyard's
# upstream-notes.sh writes the link; the repo says WHERE, in a COMMITTED build/ or scripts/
# upstream-release-notes-url.sh -- or says in INGREDIENTS.md why there is nothing to link ("No
# upstream release notes: <reason>": a repo that is its own upstream, a bundle with no single one).
# Committed, not merely present: macports-legacy-support's .gitignore ignores build/ wholesale, so
# `git add -A` skipped its new hook without a word, and CI's fresh checkout would never have seen it.
hook_tracked=no; hook_present=no
for d in build scripts; do
  if git ls-files --error-unmatch "$d/upstream-release-notes-url.sh" >/dev/null 2>&1; then hook_tracked=yes; fi
  if [ -f "$d/upstream-release-notes-url.sh" ]; then hook_present=yes; fi
done
if [ "$hook_tracked" = no ] && ! grep -q 'No upstream release notes: *[^ ]' INGREDIENTS.md 2>/dev/null; then
  if [ "$hook_present" = yes ]; then
    fail "upstream-release-notes-url.sh exists but is not committed — a .gitignore'd build/ drops it silently, and CI's fresh checkout never sees it" \
         "git add -f it (and ignore only build OUTPUT dirs, never build/ itself)"
  else
    fail "a release shipping a new upstream cannot link upstream's notes: no committed build/upstream-release-notes-url.sh, and INGREDIENTS.md does not say why" \
         "add the hook (usually one printf -- see the conventions skill, 'A new upstream links upstream's own notes'), or a line 'No upstream release notes: <reason>' in INGREDIENTS.md"
  fi
fi

# 12. A workflow that signs proves its logs don't carry the signing key. A run of sign_and_appcast.sh
# has SPARKLE_PRIVATE_KEY in its environment and a public log; scan-for-key.yml (between the signing
# job and publish, under always()) scans that run's logs and release files for any piece of the key,
# and publish-release.yml REFUSES a signed release without its record. Checked here so a repo that
# signs without the scan job fails its own PR, not its next release.
if ci_mentions 'sign_and_appcast'; then
  ci_mentions 'scan-for-key.yml' \
    || fail "a workflow signs (sign_and_appcast.sh) but none calls scan-for-key.yml — publish-release.yml refuses a signed release with no scan record" \
            "add a scan job between the signing job and publish, under always() (the snippet is at the top of shipyard's scan-for-key.yml), and make publish need it"
fi

# 13. A pin on a -mavericks.N release must be read with versioning that COMPARES N. Renovate's default
# versioning coerces the suffix away, so 6.3.3-mavericks.1 and .4 compare EQUAL and the bot proposes
# nothing -- no PR, no error, the dependency looks tracked on the Dashboard. swift-runtime's
# swift-toolchain pin stayed at .1 through .2, .3 and .4 -- six weeks after check 9's lesson wired its
# manager on 2026-07-31, which fixed "nothing tracks it" and left "nothing can see a new one".
# The shared preset's legacysupport manager and the golang consumers (container-tools, tailscale) do it
# right; this asks every other manager to match.
#
# Decided from the PIN, not the dep's name: run each regex manager over the files it names and look at
# what it captures. A repo tracking a self-upstream sibling (YYYYMMDD.N, vX.Y.Z) or anything else
# without the suffix is left alone, and a pin captured via a named group is still seen. The versioning
# is checked by what it DOES (match the pin, capture N in a compared group), not by how it is spelled.
if [ -f .github/renovate.json ] && git rev-parse --git-dir >/dev/null 2>&1; then
  python3 - .github/renovate.json <<'PY' || status=1
import fnmatch, json, re, subprocess, sys
def js(rx):  # Renovate regexes are JS: (?<name>...) is Python's (?P<name>...); lookbehinds stay as they are
    return re.sub(r'\(\?<(?![=!])', '(?P<', rx)
def matcher(pat):
    m = re.fullmatch(r'/(.*)/([a-z]*)', pat)
    if m:
        rx = re.compile(js(m.group(1)), re.I if 'i' in m.group(2) else 0)
        return lambda f: rx.search(f) is not None
    return lambda f: fnmatch.fnmatch(f, pat)
# What Renovate sees is what is committed (the heredoc is this script's stdin, so git is asked here)
files = [f for f in subprocess.run(['git', 'ls-files', '-z'], capture_output=True, text=True,
                                   check=True).stdout.split('\0') if f]
compared = {'major', 'minor', 'patch', 'build', 'revision'}  # 'prerelease' marks a version unstable
bad = []
for mgr in json.load(open(sys.argv[1])).get('customManagers', []):
    if mgr.get('customType') != 'regex':
        continue
    pats = [matcher(p) for p in mgr.get('managerFilePatterns', [])]
    vt = mgr.get('versioningTemplate') or ''
    for f in (f for f in files if any(p(f) for p in pats)):
        try:
            text = open(f, encoding='utf-8', errors='replace').read()
        except OSError:
            continue
        for ms in mgr.get('matchStrings', []):
            for m in re.finditer(js(ms), text, re.M):
                cv = (m.groupdict().get('currentValue') or '').strip()
                n = re.search(r'-mavericks\.(\d+)$', cv)
                if not n:
                    continue
                vm = re.match(js(vt[len('regex:'):]), cv) if vt.startswith('regex:') else None
                if vm and any(k in compared and v == n.group(1) for k, v in vm.groupdict().items()):
                    continue
                dep = mgr.get('depNameTemplate') or (m.groupdict().get('depName')) or mgr.get('packageNameTemplate') or '(unnamed)'
                bad.append('%s = %s (%s)' % (dep, cv, f))
if bad:
    for b in bad:
        print("check-family-conventions: Renovate cannot see new -mavericks.N releases of %s -- its versioning does not compare N, so every -mavericks.N of one upstream compares equal" % b, file=sys.stderr)
    print('    fix: give that manager "versioningTemplate": "regex:^(?<major>\\\\d+)\\\\.(?<minor>\\\\d+)\\\\.(?<patch>\\\\d+)-mavericks\\\\.(?<build>\\\\d+)$"', file=sys.stderr)
    sys.exit(1)
PY
fi

# 14. The release body is the shared generator's output, and every consumer reads that same file.
# Before Plan 2 this was five hand-rolled shapes: six products published "Automated release for Mac
# OS X 10.9 (Mavericks)." as their entire notes -- for every release, including the Renovate
# repackages whose only reason to exist was an ingredient bump -- and tailscale published an empty
# body. All 13 now call release-notes.sh; this is what stops the fourteenth, and the next edit to the
# first thirteen, from going back. The publisher checks the body's SHAPE at release time
# (check-release-notes.sh); this checks the WIRING on the PR, which is where a human can still fix it
# cheaply.
#
# Check 5 stays: it is the weak form ("some notes reached the release") and still covers a repo that
# has not adopted publish-release.yml. A repo that satisfies only 5 -- via --generate-notes, say --
# now fails 14, which is the point.
#
# Every presence question here goes through ci_mentions() rather than a second $CI_FILES grep: that
# helper already answers "does any workflow say this?", already passes the pattern with -e so a
# leading dash is safe, and already handles a repo with no workflows. A guard that re-derives what a
# sibling already decides is a guard that drifts.
if [ -n "$CI_FILES" ]; then
  # `[/ ]` and not a bare name, because check-release-notes.sh is the PUBLISHER's shape gate -- a
  # different script that writes no body -- and it contains "release-notes.sh" as a substring. Every
  # real caller spells it "$SHIPYARD_SCRIPTS/release-notes.sh", so the slash is always there.
  ci_mentions '[/ ]release-notes\.sh' \
    || fail "no workflow builds the release body with the shared generator (release-notes.sh)" \
            "call \$SHIPYARD_SCRIPTS/release-notes.sh --tag/--version/--product --out dist/RELEASE_NOTES.md"

  # A hand-written body is the exact regression this check exists for. Both shapes the family used:
  # a printf redirect, and copying a committed file straight in (porthole shipped its README.md as
  # the body of every release).
  #
  # NOT anchored on "dist/": magic-trackpad2 stages its body at build/RELEASE_NOTES.md, which is
  # correct -- the directory is the caller's business, the file is what matters. Anchoring on dist/
  # would have let a hand-written build/RELEASE_NOTES.md through in the one repo that uses it.
  #
  # The cp pattern is not anchored at the start of the line either: `- run: cp x dist/REL...` is one
  # of the two ways a step gets written, and a `^[[:space:]]*cp` sees only the other -- this check's
  # own fixture caught that. What it DOES demand is that RELEASE_NOTES.md be the cp's LAST word, the
  # DESTINATION. Copying the generated body somewhere else (`cp dist/RELEASE_NOTES.md build/`) reads
  # the file rather than writing it, and is what a repo staging it into an artifact would rightly do.
  if ci_mentions '>[[:space:]]*[^ ]*RELEASE_NOTES\.md' \
     || ci_mentions '[[:space:]]cp[[:space:]][^;&|]*[[:space:]][^ ;&|]*RELEASE_NOTES\.md'; then
    fail "a workflow hand-writes the release body into RELEASE_NOTES.md" \
         "delete it -- release-notes.sh --out <path> is the only thing that writes that file"
  fi

  # GitHub's autogenerated body is a commit list. It is not the Sparkle <description> a 10.9 user
  # reads in the update dialog, which is what this family's body has to be.
  #
  # `if`, not `ci_mentions ... && fail ...`: this gate accumulates failures and reports them all, so
  # no check may abort the run. An AND-OR list that ends a block is the shape that does abort under
  # `set -eu`, and a check 15 appended below would never run.
  if ci_mentions '--generate-notes'; then
    fail "a workflow publishes GitHub's autogenerated notes (--generate-notes)" \
         "build the body with release-notes.sh; --generate-notes cannot say which ingredient moved"
  fi

  # The appcast and the Release page must tell the same story, so the file sign_and_appcast.sh reads
  # has to be a file the generator wrote. Compared as SETS: golang renders two appcasts from one
  # body, which is correct and must keep passing.
  #
  # Two things the family's real workflows require, both verified against all 12 reachable product
  # repos' main on 2026-09-12 before this shipped -- @v1 reaches every consumer within minutes, and
  # check 7d reddened two repos within the hour on 2026-09-09 by shipping unswept:
  #  - The value may be QUOTED. magic-trackpad2 writes --notes-file "build/RELEASE_NOTES.md" and
  #    swift-runtime writes --notes-file "dist/RELEASE_NOTES.md"; a character class that excludes the
  #    quote captures an EMPTY value for both and fails two correct repos.
  #  - --out is not release-notes.sh's flag alone. container-tools and tailscale both pass
  #    --out "$PKG" to cmake/package_pkg.sh, so an unfiltered --out set would also vouch for
  #    --notes-file "$PKG" as "something the generator wrote". Only .md values count.
  strip_arg() {  # $1 = the flag itself, e.g. '--out'; prints each value it is given, unquoted, once
    # -e for the same reason ci_mentions uses it: a pattern starting with '-' is not a grep flag.
    # `[ =]` and not just a space, which also keeps --out-dir and --output out of the --out set.
    # shellcheck disable=SC2086  # CI_FILES is a deliberate word-split list of paths
    grep -ho -e "$1[ =][\"']\{0,1\}[^ \"']*" $CI_FILES 2>/dev/null \
      | sed "s/^$1[ =][\"']\{0,1\}//" | sort -u
  }
  outs="$(strip_arg '--out' | grep '\.md$' || true)"
  ins="$(strip_arg '--notes-file' || true)"
  # 1password, ed25519, signal-desktop and swift-toolchain pass no --notes-file at all: they stage no
  # appcast from the notes, so this loop is empty. That is the right answer for them, not a gap --
  # the three clauses above are what cover those repos.
  #
  # Deliberately NOT checked: a bare `--notes "<text>"` on a gh release call. porthole uses one for
  # its feed-porthole moving-tag release and golang for each go-line feed; those are feed pointers,
  # not product release bodies, and failing them would redden two correct repos.
  for n in $ins; do
    printf '%s\n' "$outs" | grep -qxF "$n" \
      || fail "a workflow reads a notes file the generator does not write: --notes-file $n" \
              "pass the same path release-notes.sh was given as --out"
  done
fi

# LAST, after every check: this line used to sit mid-script, so checks appended below it printed
# "ok" and then failed in the same run.
[ "$status" -eq 0 ] && echo "check-family-conventions: ok"

exit "$status"
