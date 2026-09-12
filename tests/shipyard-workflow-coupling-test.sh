#!/bin/sh
# Two couplings that are invisible in the file that breaks because of them.
#
# 1. shipyard-version.sh derives the patch from `git rev-list --count HEAD` and REFUSES in a shallow
#    clone (a --depth 1 clone would silently yield 1.0.1, colliding with a real tag). So every
#    workflow that configures CMake or runs the suite must checkout with fetch-depth: 0. ci.yml did
#    not, and went red the moment the shallow guard landed -- the failure surfaced as
#    "installed package says '1.0', derived version is ''", nowhere near the checkout step.
#
# 2. Only ONE workflow may run the suite on a push to main. When two do, "the repo is red" and "we
#    published" are decided by different workflows: ci.yml failed on four consecutive commits while
#    release.yml published v1.0.126, .129, .130 and .131 from the same trees.
#
# 3. release.yml runs ONLY on a push to main, so every step it does not share with ci.yml first
#    executes on a push that is already publishing -- there is no rehearsal, and the flag-day push
#    would be the first real run of the packaging path (spec 2026-09-11, R-P1-17). So ci.yml must
#    build, install and assert the pkg on branch pushes, through the SAME scripts release.yml uses.
#    The coupling is invisible in either file: each looks complete on its own.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
wf="$here/../.github/workflows"

python3 - "$wf" <<'PY'
import sys, os, yaml
wf = sys.argv[1]
bad = []

for name in ("ci.yml", "release.yml"):
    d = yaml.safe_load(open(os.path.join(wf, name)))
    for job, spec in (d.get("jobs") or {}).items():
        for step in (spec.get("steps") or []):
            if "actions/checkout" in (step.get("uses") or ""):
                depth = (step.get("with") or {}).get("fetch-depth")
                if str(depth) != "0":
                    bad.append("%s job %s checks out with fetch-depth=%r; shipyard-version.sh "
                               "refuses a shallow clone" % (name, job, depth))

# Exactly one workflow may run the suite on a push to main.
def pushes_to_main(d):
    on = d.get("on") or d.get(True) or {}
    push = on.get("push")
    if not isinstance(push, dict):
        return False
    if "branches-ignore" in push:
        return "main" not in push["branches-ignore"]
    br = push.get("branches") or []
    return "main" in br or "**" in br

runners = []
for name in os.listdir(wf):
    if not name.endswith((".yml", ".yaml")):
        continue
    d = yaml.safe_load(open(os.path.join(wf, name)))
    if not pushes_to_main(d):
        continue
    body = open(os.path.join(wf, name)).read()
    if "run-repo-tests" in body:
        runners.append(name)

if len(runners) != 1:
    bad.append("%d workflows run the suite on a push to main (%s); exactly one must, or a red repo "
               "can still publish" % (len(runners), ", ".join(sorted(runners)) or "none"))

if bad:
    for b in bad:
        print("FAIL:", b)
    sys.exit(1)
print("ok: full-depth checkouts, and one suite-runner on main")
PY

python3 - "$wf" <<'PY'
import os, re, sys, yaml
wf = sys.argv[1]
bad = []

# COMMANDS, not the file's text: both files' comments name these scripts, so a substring search over
# the text stays green after the invocation itself is deleted.
def cmds(name):
    d = yaml.safe_load(open(os.path.join(wf, name)))
    out = []
    for spec in (d.get("jobs") or {}).values():
        for step in (spec.get("steps") or []):
            lines = [l for l in (step.get("run") or "").splitlines() if not l.lstrip().startswith("#")]
            joined = re.sub(r"\\\s*\n\s*", " ", "\n".join(lines))
            out += [" ".join(l.split()) for l in joined.splitlines() if l.strip()]
    return out

ci, rel = cmds("ci.yml"), cmds("release.yml")
def has(cs, pat): return any(re.search(pat, c) for c in cs)

# Each of these is a step release.yml would otherwise run for the first time while publishing.
# The two install-smoke lines carry their failure plumbing INTO the pattern. Both run under `set -eu`
# with the failure caught, so the installer log can be dumped before the step dies -- and `|| true` in
# place of `|| bad=1` turns the whole smoke into decoration while every other assertion stays green
# (R-P1-20). A pattern that stops at the command name cannot see that.
for pat, what in ((r"^sh scripts/lipo-merge-tree\.sh ", "merge the two updater builds (scripts/lipo-merge-tree.sh)"),
                  (r"^sh scripts/package-pkg\.sh ", "build the pkg (scripts/package-pkg.sh)"),
                  (r"^sh scripts/assert_pkg_installs_in_place\.sh ", "gate the pkg (scripts/assert_pkg_installs_in_place.sh)"),
                  (r"^sudo installer -pkg .* \|\| bad=1$", "install the pkg on the runner, recording failure (sudo installer ... || bad=1)"),
                  (r"^sh scripts/assert-installed-shipyard\.sh .* \|\| bad=1$",
                   "assert the install, recording failure (scripts/assert-installed-shipyard.sh ... || bad=1)")):
    if not has(rel, pat):
        bad.append("release.yml no longer does: %s" % what)
    elif not has(ci, pat):
        bad.append("ci.yml does not rehearse release.yml's packaging path: it never runs %s, so that "
                   "step's first real execution would be a push that is already publishing" % what)

# ONE statement of what an installed shipyard must look like. Either workflow asserting it inline is
# how the two drift apart, and the fixture test then covers neither.
for name, cs in (("ci.yml", ci), ("release.yml", rel)):
    for pat, what in ((r"cmake version ", "the CMake version"),
                      (r"\benv -i\b", "the stripped-environment find_package probe"),
                      # The INSTALLED app specifically. `lipo -info` on the freshly merged bundle in
                      # $RUNNER_TEMP is the merge step logging what it produced, not a claim about
                      # what Installer put on the volume.
                      (r"^lipo -info .*/Library/Application Support/ModernMavericks/", "the installed updater's architectures")):
        if has(cs, pat):
            bad.append("%s asserts %s inline; that belongs in scripts/assert-installed-shipyard.sh, "
                       "which both workflows and tests/assert-installed-shipyard-test.sh share" % (name, what))

# R-P1-19: install@v1 may not nest `uses: ./.github/actions/shipyard-cmake` -- that path resolves
# against the CONSUMER's workspace, and nested actions are prepared before step `if:` conditions are
# evaluated, so every consumer would break on a step that was never going to run. The tree is
# therefore built by the CALLING workflow. That is a coupling: it lives in neither file alone, and
# each looks complete without it.
for name in ("ci.yml", "release.yml"):
    d = yaml.safe_load(open(os.path.join(wf, name)))
    for job, spec in (d.get("jobs") or {}).items():
        steps = spec.get("steps") or []
        for step in steps:
            if str(step.get("uses", "")) != "./.github/actions/install":
                continue
            with_ = step.get("with") or {}
            if with_.get("source") != "build":
                continue
            if "outputs.tree" not in str(with_.get("cmake-tree", "")):
                bad.append("%s job %s installs with source: build but passes no cmake-tree from "
                           "./.github/actions/shipyard-cmake; install@v1 cannot fetch it itself "
                           "(R-P1-19)" % (name, job))
            elif not any(str(t.get("uses", "")) == "./.github/actions/shipyard-cmake" for t in steps):
                bad.append("%s job %s passes a cmake-tree but never runs "
                           "./.github/actions/shipyard-cmake to produce it" % (name, job))

if bad:
    for b in bad:
        print("FAIL:", b)
    sys.exit(1)
print("ok: ci.yml rehearses the packaging path release.yml only ever runs while publishing, and both "
      "hand install@v1 the CMake tree rather than letting it nest a local action")
PY
echo "PASS: shipyard-workflow-coupling"
