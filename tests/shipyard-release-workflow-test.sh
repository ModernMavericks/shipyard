#!/bin/sh
# shipyard must publish itself with the tooling from the COMMIT BEING BUILT, never from @v1.
#
# Otherwise it ships a version using the previous version's publish path and cannot catch a defect in
# the tooling it is shipping. That is not hypothetical: on 2026-09-09 a defect in conventions check 7d
# reached fifteen repos through @v1 and reddened two of them within the hour.
#
# This is the rule most likely to be quietly reverted -- @v1 is what every OTHER repo writes, and it
# looks equally correct here -- and its failure mode stays invisible until the tooling is broken.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
w="$here/../.github/workflows/release.yml"
[ -f "$w" ] || { echo "FAIL: no release.yml"; exit 1; }

python3 - "$w" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))

pub = [j for j in wf["jobs"].values() if "publish-release.yml" in (j.get("uses") or "")]
if not pub:
    print("FAIL: no job calls publish-release.yml"); sys.exit(1)
p = pub[0]

# A LOCAL uses: path resolves to this very commit. `@v1` would be the previous version's workflow.
if not (p.get("uses") or "").startswith("./"):
    print("FAIL: publish must be called by local path (./.github/...), not a @ref: %r" % p.get("uses")); sys.exit(1)

ref = str((p.get("with") or {}).get("shipyard-ref", ""))
if "github.sha" not in ref:
    print("FAIL: shipyard-ref must be github.sha, not %r -- else release-assets.sh comes from @v1" % ref); sys.exit(1)

# Trigger: every push to main, so the version cannot fall behind the content.
on = wf.get("on") or wf.get(True)
branches = ((on.get("push") or {}).get("branches")) or []
if "main" not in branches:
    print("FAIL: release.yml must trigger on push to main; got %r" % (branches,)); sys.exit(1)

# The publishing side must be alone in its concurrency group (check 1b).
grp = str((wf.get("concurrency") or {}).get("group", ""))
if "github.run_id" not in grp:
    print("FAIL: concurrency group must be keyed per run: %r" % grp); sys.exit(1)
print("ok: publishes from the commit under test, on every push to main, alone in its group")
PY
echo "PASS: shipyard-release-workflow"
