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
    # release-state.sh refuses (exit 2) a declared `upstream` that is not the file version.sh reads.
    # So a product whose upstream lives elsewhere -- container-tools and tailscale
    # (components/*/version), golang (lines/126/UPSTREAM_VERSION) -- cannot render state here at all
    # unless it can say where: without this input it would hard-fail nightly from its first run after
    # adopting the documented ten-line caller.
    if "upstream-file" not in ins:
        fail.append("reconcile.yml has no upstream-file input: a product whose upstream is not "
                    "UPSTREAM_VERSION cannot render state here, because release-state.sh exits 2 "
                    "when the declared upstream is not the file version.sh reads")
    elif ins["upstream-file"].get("default") != "":
        fail.append("upstream-file must default to '' -- both readers use "
                    "${MAVERICKS_UPSTREAM_FILE:-UPSTREAM_VERSION}, so empty means the default path")

# ...and the input has to REACH the scripts. An input nothing wires through is the same hard failure
# with an extra place to look.
state_steps = [s for j in wf["jobs"].values() for s in j.get("steps", []) if s.get("id") == "state"]
if not state_steps:
    fail.append("reconcile.yml has no step with id: state -- the digest and version come from there")
else:
    env = state_steps[0].get("env") or {}
    if "upstream-file" not in str(env.get("MAVERICKS_UPSTREAM_FILE", "")):
        fail.append("the state step does not set MAVERICKS_UPSTREAM_FILE from inputs.upstream-file: "
                    "both release-state.sh and version.sh read it there, and they must agree")

# The whole point of the backstop is that a quiet night is nearly free. macOS here would be 14
# product builds a night.
for job, spec in wf["jobs"].items():
    if "macos" in str(spec.get("runs-on", "")):
        fail.append(f"job {job} runs on macos: the backstop must stay on ubuntu (one API call a night)")

perms = wf.get("permissions", {})
if perms.get("actions") != "write":
    fail.append("reconcile.yml needs permissions.actions: write -- it dispatches the release run, and "
                "without it the backstop fails as silently as the lost release it exists to catch")
# It reads main and it reads releases; it must NOT be able to write one. The backstop used to
# backfill a digest onto a release it had INFERRED was this state from a version match -- and
# version.sh's `auto` mode maps every declared state of one upstream to one version, so that write
# could cement an unreleased state onto a release that did not contain it, permanently and silently
# (ruling 16). Marking a pre-migration release is a one-time migration step a human runs, with the
# digest computed exactly from that tag's own tree.
if perms.get("contents") != "read":
    fail.append("reconcile.yml must declare permissions.contents: read, not write -- the backstop "
                "reads state and dispatches; it never edits a release")

text = p.read_text()
for needed in ("release-state.sh", "release-needed.sh"):
    if needed not in text:
        fail.append(f"reconcile.yml never calls {needed}")
# The step cannot creep back: asserting the permission alone would not stop someone re-adding the
# call and then "fixing" the permission it needs. Matched on the INVOCATION form, not the bare name:
# $SHIPYARD_SCRIPTS is this workflow's only path to shipyard's scripts, so that prefix is the only
# way it could call one -- while NAMING the script in the unreadable-marker guidance is exactly what
# that warning has to do, since running it by hand is the escape.
if "SHIPYARD_SCRIPTS/release-state-record.sh" in text:
    fail.append("reconcile.yml calls release-state-record.sh -- the nightly backstop must never "
                "write a digest onto a release. That write is a migration step, run once, with a "
                "digest computed from the released tag's own tree (release-state.sh --ref)")
# main is where state is DECLARED; a branch is a proposal (spec decision 3).
if "ref: main" not in text:
    fail.append("reconcile.yml must check out main: a branch is a proposal, not a declaration")

if fail:
    for f in fail: print("FAIL: " + f)
    sys.exit(1)
print("ok: reconcile.yml")
PY

echo "PASS: reconcile-workflow"
