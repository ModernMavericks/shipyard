#!/bin/sh
# reconcile.yml: the reusable backstop that notices a declared state was never realised.
#
# An event-driven release has exactly one chance to happen (a push, a tag) -- if that one chance is
# lost (concurrency eviction, a failed dispatch), nothing else ever asks again. This workflow runs on
# a schedule, renders main's declared state, and asks release-needed.sh whether any release already
# carries that digest -- deliberately cheap (ubuntu, no build) so a quiet night costs one API call.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3"; exit 77; }
python3 -c 'import yaml' >/dev/null 2>&1 || { echo "SKIP: no PyYAML"; exit 77; }

python3 - "$root" <<'PY'
import sys, yaml, pathlib
root = pathlib.Path(sys.argv[1])
p = root / ".github/workflows/reconcile.yml"
if not p.exists():
    print("FAIL: no .github/workflows/reconcile.yml"); sys.exit(1)
fail = []
wf = yaml.safe_load(p.read_text())
on = wf.get("on", wf.get(True))

if "workflow_call" not in on:
    fail.append("reconcile.yml must be reusable (workflow_call)")
else:
    ins = on["workflow_call"].get("inputs", {})
    for name, default in (("release-workflow", "release.yml"), ("dispatch-field", "local_release=true")):
        if name not in ins:
            fail.append(f"reconcile.yml has no {name} input")
        elif ins[name].get("default") != default:
            fail.append(f"{name} default must be {default!r}, matching repackage-on-ingredient-bump.yml")

# The whole point of the backstop is that a quiet night is nearly free. macOS here would be 14
# product builds a night.
for job, spec in wf["jobs"].items():
    if "macos" in str(spec.get("runs-on", "")):
        fail.append(f"job {job} runs on macos: the backstop must stay on ubuntu (one API call a night)")

perms = wf.get("permissions", {})
if perms.get("actions") != "write":
    fail.append("reconcile.yml needs permissions.actions: write -- it dispatches the release run, and "
                "without it the backstop fails as silently as the lost release it exists to catch")

text = p.read_text()
for needed in ("release-state.sh", "release-needed.sh"):
    if needed not in text:
        fail.append(f"reconcile.yml never calls {needed}")
# main is where state is DECLARED; a branch is a proposal (spec decision 3).
if "ref: main" not in text:
    fail.append("reconcile.yml must check out main: a branch is a proposal, not a declaration")

if fail:
    for f in fail: print("FAIL: " + f)
    sys.exit(1)
print("ok: reconcile.yml")
PY

echo "PASS: reconcile-workflow"
