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
python3 - "$w" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
body = open(sys.argv[1]).read()

# Both slices must be built, or the pkg cannot serve both kinds of developer.
for need in ("SHIPYARD_BUILD_UPDATER", "package-pkg.sh", "sign_and_appcast.sh"):
    if need not in body:
        print("FAIL: release.yml never invokes %s" % need); sys.exit(1)
if "arm64" not in body or "x86_64" not in body:
    print("FAIL: release.yml does not build both updater slices"); sys.exit(1)

# The tarball is retired: nothing consumed it, and GitHub ships source archives for free.
if "tar -czf" in body or "shipyard-$v.tar.gz" in body:
    print("FAIL: the release tarball should be gone; the pkg is the asset now"); sys.exit(1)

# The built pkg is gated the way the family gates one: what the installer does on a box that has the
# previous version, and whether the artifacts agree with each other.
for need in ("assert_pkg_installs_in_place.sh", "check-artifact-conformance.sh"):
    if need not in body:
        print("FAIL: release.yml never runs %s on the pkg" % need); sys.exit(1)

# shipyard's tags are vX.Y.Z. Without --tag-glob the upgradeable gate sees none of them, finds no
# previous release, and skips the ordering check on every release.
if "assert_appcast_upgradeable.sh" not in body or "--tag-glob" not in body:
    print("FAIL: release.yml must run assert_appcast_upgradeable.sh with --tag-glob"); sys.exit(1)

# release-notes-file.sh prints a PATH. The body must be the file's content, and must not be empty.
if "::error::release notes came back empty" not in body:
    print("FAIL: release.yml lost the empty-release-notes guard"); sys.exit(1)
print("ok: builds both slices, packages, gates the pkg, signs an appcast, ships no tarball")
PY
echo "PASS: shipyard-release-workflow"
