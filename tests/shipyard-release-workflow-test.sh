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
import re, sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))

# Inspect COMMANDS, never the file's text: release.yml's comments name every one of these scripts and
# flags, so a substring search stays green after the invocation itself is deleted. Take every step's
# parsed `run:` body, drop whole-line comments, and join backslash continuations so one command is one
# line. (Only whole-line comments: a trailing '#' cannot be told from ${x#v} without a shell parser.)
def step_cmds(step):
    lines = [l for l in (step.get("run") or "").splitlines() if not l.lstrip().startswith("#")]
    joined = re.sub(r"\\\s*\n\s*", " ", "\n".join(lines))
    return [" ".join(l.split()) for l in joined.splitlines() if l.strip()]

cmds = []
for job in (wf.get("jobs") or {}).values():
    for step in (job.get("steps") or []):
        cmds += step_cmds(step)

def find(pattern):
    return [c for c in cmds if re.search(pattern, c)]

bad = []
def need(pattern, why):
    if not find(pattern):
        bad.append(why)

# Both slices must be configured with the updater on AND built, or the pkg cannot serve both kinds
# of developer.
for arch in ("x86_64", "arm64"):
    conf = find(r"^cmake -S \S+ -B (\S+) .*-DSHIPYARD_BUILD_UPDATER=ON\b.*-DCMAKE_OSX_ARCHITECTURES=%s\b" % arch) \
        + find(r"^cmake -S \S+ -B (\S+) .*-DCMAKE_OSX_ARCHITECTURES=%s\b.*-DSHIPYARD_BUILD_UPDATER=ON\b" % arch)
    if not conf:
        bad.append("no configure of the %s updater slice (-DSHIPYARD_BUILD_UPDATER=ON -DCMAKE_OSX_ARCHITECTURES=%s)" % (arch, arch))
        continue
    bdir = re.search(r"-B (\S+)", conf[0]).group(1)
    if not find(r"^cmake --build %s(\s|$)" % re.escape(bdir)):
        bad.append("the %s updater slice is configured in %s but never built" % (arch, bdir))

# One pkg, from this checkout's package-pkg.sh, carrying each slice under the name its postinstall
# looks for.
need(r"^sh scripts/package-pkg\.sh .*--app-native \S*/MavericksShipyardUpdater\.app\"? .*--app-cross \S*/MavericksShipyardCrossUpdater\.app\"?",
     "release.yml never runs scripts/package-pkg.sh with the native and cross updater apps")

# The built pkg is gated the way the family gates one: what the installer does on a box that has the
# previous version, and whether the artifacts agree with each other.
need(r"^sh scripts/assert_pkg_installs_in_place\.sh \S*\.pkg\"?$",
     "release.yml never runs scripts/assert_pkg_installs_in_place.sh on the pkg")
need(r"^sh scripts/artifact-facts\.sh dist \S+ \| sh scripts/check-artifact-conformance\.sh$",
     "release.yml never pipes artifact-facts.sh into scripts/check-artifact-conformance.sh")

# Signed, with the appcast written into the release.
need(r"^sh scripts/sign_and_appcast\.sh .*--pkg \S+\.pkg\"? > dist/appcast\.xml$",
     "release.yml never runs scripts/sign_and_appcast.sh into dist/appcast.xml")

# shipyard's tags are vX.Y.Z. Without --tag-glob the upgradeable gate sees none of them, finds no
# previous release, and skips the ordering check on every release.
need(r"^sh scripts/assert_appcast_upgradeable\.sh .*--appcast dist/appcast\.xml .*--tag-glob 'v\*\.\*\.\*'",
     "release.yml must run scripts/assert_appcast_upgradeable.sh on dist/appcast.xml with --tag-glob 'v*.*.*'")

# release-notes.sh is called directly (no wrapper): --out writes the body straight to
# dist/RELEASE_NOTES.md. shipyard passes no --min-os -- it ships shell scripts and a CMake package,
# not a 10.9 .pkg install of ITSELF, so the wrapper's hardcoded floor line would have been a lie here.
need(r"^sh \"\$SHIPYARD_SCRIPTS/release-notes\.sh\" --tag \"v\$v\" --version \"\$v\" --product Shipyard --out dist/RELEASE_NOTES\.md$",
     "release.yml must call release-notes.sh directly with --product Shipyard --out dist/RELEASE_NOTES.md")
if any("--min-os" in c for c in find(r"release-notes\.sh")):
    bad.append("release.yml must not pass --min-os to release-notes.sh -- shipyard is not a 10.9 .pkg of itself")
need(r"^\[ -s dist/RELEASE_NOTES\.md \] \|\| \{ echo \"::error::release notes came back empty\"; exit 1; \}$",
     "release.yml lost the empty-release-notes guard")

# The tarball is retired: nothing consumed it, and GitHub ships source archives for free.
tars = find(r"(^|[\s;|&(])tar\s") + find(r"\.tar\.gz\b")
if tars:
    bad.append("the release tarball should be gone; the pkg is the asset now: %r" % tars[0])

# The pkg is INSTALLED on this Apple Silicon runner before it is uploaded, and the updater left behind
# must be the arm64 one. That is the only place the arm-picking postinstall ever runs for real before a
# developer's box does: nothing on the 10.9 box can build or exercise the arm64 slice, and a pkg whose
# scripts ran under Rosetta would keep the x86_64 updater (and delete the arm64 one) with every other
# gate green. Checked within ONE step, bounded by timeout-minutes, ahead of the upload.
build = wf["jobs"]["build"]["steps"]
smoke = [i for i, s in enumerate(build)
         if any(re.search(r'^sudo installer -pkg "?dist/mavericks-shipyard-\$v\.pkg"? -target /(\s|$)', c) for c in step_cmds(s))]
if not smoke:
    bad.append('release.yml never installs the pkg on the runner (sudo installer -pkg "dist/mavericks-shipyard-$v.pkg" -target /)')
else:
    i = smoke[0]
    s = build[i]
    sc = step_cmds(s)
    exe = r'^exe="/Library/Application Support/ModernMavericks/MavericksShipyardCrossUpdater\.app/Contents/MacOS/MavericksShipyardCrossUpdater"$'
    arch = r"""^lipo -info "\$exe" \| grep -q 'is architecture: arm64\$' \|\| fail """
    if not (any(re.search(exe, c) for c in sc) and any(re.search(arch, c) for c in sc)):
        bad.append("the install smoke never asserts the remaining updater (MavericksShipyardCrossUpdater) is arm64 via lipo -info")
    if not s.get("timeout-minutes"):
        bad.append("the install smoke step has no timeout-minutes; an install that hangs would hold the runner for the job's whole budget")
    up = [j for j, t in enumerate(build) if str(t.get("uses", "")).startswith("actions/upload-artifact")]
    if not up or i > up[0]:
        bad.append("the install smoke must run BEFORE upload-artifact, so a pkg that fails it is never published")

if bad:
    for b in bad:
        print("FAIL: " + b)
    sys.exit(1)
print("ok: builds both slices, packages, gates the pkg, signs an appcast, install-smokes it, ships no tarball")
PY
echo "PASS: shipyard-release-workflow"
