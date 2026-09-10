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
echo "PASS: shipyard-workflow-coupling"
