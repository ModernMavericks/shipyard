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

build_steps = wf["jobs"]["build"]["steps"]

# shipyard builds with its own cmake: the build job installs itself in source-build mode. It cannot
# install a RELEASED shipyard to test the commit that is about to become one.
inst = [s for s in build_steps
        if str(s.get("uses", "")) == "./.github/actions/install" and (s.get("with") or {}).get("source") == "build"]
if not inst:
    bad.append("the build job must use ./.github/actions/install with source: build")
# ...and the CMake tree is built by THIS WORKFLOW and handed in. install@v1 must not reach for it
# itself: see the R-P1-19 note in the install-action block at the end of this file.
elif "outputs.tree" not in str((inst[0].get("with") or {}).get("cmake-tree", "")):
    bad.append("the build job must pass cmake-tree: the `tree` output of ./.github/actions/shipyard-cmake "
               "into install@v1 (R-P1-19); got %r" % (inst[0].get("with") or {}).get("cmake-tree"))
elif not any(str(s.get("uses", "")) == "./.github/actions/shipyard-cmake" for s in build_steps):
    bad.append("the build job passes a cmake-tree but never runs ./.github/actions/shipyard-cmake to produce it")

# One universal updater: configured per arch at its own floor (the loop supplies $1/$2), built, merged.
need(r'^for a in "x86_64 10\.9" "arm64 11\.0"; do$',
     "the updater must be built for exactly x86_64/10.9 and arm64/11.0")
need(r'^shipyard-cmake -S \. -B "?\$RUNNER_TEMP/upd-\$1"? .*-DSHIPYARD_BUILD_UPDATER=ON\b.*'
     r'-DCMAKE_OSX_ARCHITECTURES="?\$1"? -DCMAKE_OSX_DEPLOYMENT_TARGET="?\$2"?',
     "no per-arch shipyard-cmake configure of the updater (-DCMAKE_OSX_ARCHITECTURES/-DCMAKE_OSX_DEPLOYMENT_TARGET)")
need(r'^shipyard-cmake --build "?\$RUNNER_TEMP/upd-\$1"?$', "the per-arch updater builds are never built")
need(r"^sh scripts/lipo-merge-tree\.sh .*--require-archs \"x86_64 arm64\"$",
     "the two updater builds are never merged with lipo-merge-tree.sh --require-archs \"x86_64 arm64\"")
# ...and merged STRICTLY. updater/Info.plist.in fixes LSMinimumSystemVersion at the family's floor
# instead of deriving it per build, so the two plists are byte-identical and the flag is not needed;
# passing it anyway would let a real future divergence through silently, which is the opposite of what
# that file's comment promises. If they ever do differ, fix the plist, not this line.
if find(r"^sh scripts/lipo-merge-tree\.sh .*--allow-differ"):
    bad.append("the updater merge passes --allow-differ; nothing in updater/Info.plist.in is "
               "arch-dependent, so a difference there is a defect to fix, not one to declare")
# ...and the result is asserted, not assumed. The merge is NOT followed by a re-sign: lipo copies each
# slice byte for byte, so the ad-hoc signature ld gives the arm64 slice -- all Apple Silicon needs to
# run it -- survives, and nothing in shipyard's build seals this bundle for a re-seal to restore.
# `codesign --deep` in particular must not come back: the app carries Sparkle as a VERSIONED
# framework, which `--verify --deep` calls ambiguous on every runner (R-P1-22).
for arch in ("x86_64", "arm64"):
    need(r'^case " \$archs " in \*" %s "\*\) ;; \*\) echo "::error::the merged updater has no %s slice' % (arch, arch),
         "the merged updater's %s slice is never asserted after the merge" % arch)

# The pkg: the CMake tree + shipyard's install prefix + the merged app.
need(r"^sh scripts/package-pkg\.sh .*--cmake-tree \S+ .*--shipyard-prefix \S+ .*--app \S*/MavericksShipyardUpdater\.app\"?",
     "release.yml never runs scripts/package-pkg.sh with --cmake-tree, --shipyard-prefix and the merged --app")

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

# release-notes-file.sh prints a PATH. The body must be the file's content, and must not be empty.
need(r"^cp \"\$notes_path\" dist/RELEASE_NOTES\.md$",
     "release.yml no longer copies the notes FILE (release-notes-file.sh prints a path) into dist/RELEASE_NOTES.md")
need(r"^\[ -s dist/RELEASE_NOTES\.md \] \|\| \{ echo \"::error::release notes came back empty\"; exit 1; \}$",
     "release.yml lost the empty-release-notes guard")

# The tarball is retired: nothing consumed it, and GitHub ships source archives for free.
tars = find(r"(^|[\s;|&(])tar\s") + find(r"\.tar\.gz\b")
if tars:
    bad.append("the release tarball should be gone; the pkg is the asset now: %r" % tars[0])

# The pkg is INSTALLED on this Apple Silicon runner before it is uploaded. That is the only place the
# pkg's scripts ever run for real before a developer's box sees them, and nothing on the 10.9 box can
# build or exercise the arm64 half. WHAT must then hold of the install is stated once, in
# scripts/assert-installed-shipyard.sh (R-P1-17) -- this step must not restate it inline, or the two
# callers drift and the fixture test stops covering either. Checked within ONE step, bounded by
# timeout-minutes, ahead of the upload.
smoke = [i for i, s in enumerate(build_steps)
         if any(re.search(r'^sudo installer -pkg "?dist/mavericks-shipyard-\$v\.pkg"? -target /(\s|$)', c) for c in step_cmds(s))]
if not smoke:
    bad.append('release.yml never installs the pkg on the runner (sudo installer -pkg "dist/mavericks-shipyard-$v.pkg" -target /)')
else:
    i = smoke[0]; s = build_steps[i]; sc = step_cmds(s)
    def has(p): return any(re.search(p, c) for c in sc)
    if not has(r"^want=\"\$\(sed -n 's/\^CMAKE_VERSION=//p' cmake\.pin\)\"$"):
        bad.append("the smoke never reads the pinned CMake version out of cmake.pin")
    # The PLUMBING, not just the call. Both of these run under `set -eu` with their failure caught, so
    # that the installer log can be dumped before the step dies -- and `|| true` in place of `|| bad=1`
    # makes the whole smoke decorative while every other assertion here stays green (R-P1-20).
    if not has(r'^sudo installer -pkg "?dist/mavericks-shipyard-\$v\.pkg"? -target / \|\| bad=1$'):
        bad.append("the smoke's `sudo installer` does not record its failure (|| bad=1), so a pkg that "
                   "fails to install cannot fail the step")
    if not has(r'^sh scripts/assert-installed-shipyard\.sh --cmake-version "\$want" --root / \|\| bad=1$'):
        bad.append("the smoke never runs scripts/assert-installed-shipyard.sh against the installed "
                   "root with its failure recorded (|| bad=1)")
    if not has(r'^\[ "\$bad" -eq 0 \] \|\| exit 1$'):
        bad.append("the smoke's failures never fail the step ([ \"$bad\" -eq 0 ] || exit 1)")
    if not s.get("timeout-minutes"):
        bad.append("the install smoke step has no timeout-minutes; an install that hangs would hold the runner for the job's whole budget")
    up = [j for j, t in enumerate(build_steps) if str(t.get("uses", "")).startswith("actions/upload-artifact")]
    if not up or i > up[0]:
        bad.append("the install smoke must run BEFORE upload-artifact, so a pkg that fails it is never published")

# The key scan stays between build and publish (another session's work; a rewrite must not drop it).
jobs = wf.get("jobs") or {}
if "scan-for-key.yml" not in str((jobs.get("scan") or {}).get("uses", "")):
    bad.append("the scan job (./.github/workflows/scan-for-key.yml) is gone")
if sorted((jobs.get("publish") or {}).get("needs") or []) != ["build", "scan"]:
    bad.append("publish must need exactly [build, scan]")

# Nothing of the superseded design survives in any command: no user package registry, no second
# "cross" updater app, no postinstall picking a slice by hw.optional.arm64.
for gone in (r"cmake/packages", r"register-with-cmake", r"CrossUpdater", r"hw\.optional\.arm64"):
    if find(gone):
        bad.append("release.yml still runs something mentioning %s" % gone)

if bad:
    for b in bad:
        print("FAIL: " + b)
    sys.exit(1)
print("ok: one universal updater, the prefix pkg, a shared install assertion, no tarball, scan before publish")
PY

# install@v1 is the other half of the same design: a consumer gets the PKG at the ref it pinned, and
# only shipyard itself builds from source. Parsed the same way -- commands, never the file's text.
python3 - "$here/../.github/actions/install/action.yml" <<'PY'
import re, sys, yaml
a = yaml.safe_load(open(sys.argv[1]))
bad = []
if "source" not in (a.get("inputs") or {}):
    bad.append("install@v1 has no 'source' input (release | build)")
if "cmake-tree" not in (a.get("inputs") or {}):
    bad.append("install@v1 has no 'cmake-tree' input; source: build must be HANDED the CMake tree (R-P1-19)")
steps = (a.get("runs") or {}).get("steps") or []

# R-P1-19. NO local `uses: ./...` may appear in this composite, ever. GitHub resolves such a path
# against GITHUB_WORKSPACE -- the CONSUMER's checkout, which has none of shipyard's actions -- and it
# prepares nested actions BEFORE evaluating step `if:` conditions, so guarding one with
# `inputs.source == 'build'` does not spare a consumer: their job dies with "Can't find 'action.yml'"
# for a step that was never going to run. shipyard's own CI cannot catch it, because its workspace IS
# shipyard and the path resolves there. The caller runs the composite and passes its output in.
for s in steps:
    u = str(s.get("uses", ""))
    if u.startswith("./") or u.startswith("../"):
        bad.append("install@v1 nests a LOCAL action (uses: %s). Every consumer would fail with "
                   "\"Can't find 'action.yml'\", and shipyard's CI could never reproduce it -- the "
                   "calling workflow must run it and pass the result in as an input (R-P1-19)" % u)
def cmds(pred):
    out = []
    for s in steps:
        if pred(str(s.get("if", ""))):
            lines = [l for l in (s.get("run") or "").splitlines() if not l.lstrip().startswith("#")]
            out += [" ".join(l.split()) for l in re.sub(r"\\\s*\n\s*", " ", "\n".join(lines)).splitlines() if l.strip()]
    return out
# The release path has TWO branches (R-P1-18): macOS installs the pkg, everything else exports
# shipyard's shell half out of the action's own checkout. They are separate STEPS with separate `if:`
# expressions, so "the non-macOS branch installs nothing" is a claim this can actually check -- inside
# one step's shell `if`, both halves would land in the same flat command list and be indistinguishable.
rel_mac = cmds(lambda c: "'release'" in c and "runner.os == 'macOS'" in c)
rel_oth = cmds(lambda c: "'release'" in c and "runner.os != 'macOS'" in c)
bld = cmds(lambda c: "'build'" in c)

def exports(cs, name):
    """Set in GITHUB_ENV, so LATER STEPS see it. A diagnostic `echo "... NAME=$x"` mentions the name
    without exporting anything -- and both modes print one, so a bare substring search for the name
    stays green after the export itself is deleted."""
    for i, c in enumerate(cs):
        if not re.search(r'(^|[\s"{])%s=' % name, c):
            continue
        if re.search(r'>> "\$GITHUB_ENV"$', c):
            return True
        for later in cs[i + 1:]:          # a { ... } group: the redirect rides the closing brace
            if re.match(r'^\}\s*>> "\$GITHUB_ENV"$', later):
                return True
            if later.startswith("}"):
                break
    return False

for pat, why in ((r'resolve-action-version\.sh', "the macOS release path never resolves its ref to a version"),
                 (r'^gh release download "v\$ver" -R ModernMavericks/shipyard --pattern ', "the macOS release path never downloads the release's pkg"),
                 (r'^sudo installer -pkg ', "the macOS release path never installs the pkg")):
    if not any(re.search(pat, c) for c in rel_mac): bad.append(why)
if not exports(rel_mac, "SHIPYARD_SCRIPTS"):
    bad.append("the macOS release path never exports SHIPYARD_SCRIPTS")

# R-P1-18: a non-macOS runner gets shipyard's shell half, pinned to the ref, and nothing installed.
# repackage-on-ingredient-bump.yml runs on ubuntu-latest and wants exactly that.
if not rel_oth:
    bad.append("install@v1 has no non-macOS release path; ubuntu jobs that want only shipyard's "
               "shell half (repackage-on-ingredient-bump.yml) would fail (R-P1-18)")
else:
    if not exports(rel_oth, "SHIPYARD_SCRIPTS"):
        bad.append("the non-macOS release path never exports SHIPYARD_SCRIPTS")
    if not any("GITHUB_ACTION_PATH" in c for c in rel_oth):
        bad.append("the non-macOS release path must take its scripts from the action's OWN checkout "
                   "($GITHUB_ACTION_PATH/../../..), which is shipyard at the ref the consumer pinned")
    # R-P1-23: find_package(MavericksShipyard) has to RESOLVE there too -- container-tools' two
    # ubuntu-latest jobs do exactly that. SHIPYARD_SCRIPTS alone does not make find_package work.
    if not exports(rel_oth, "MavericksShipyard_DIR"):
        bad.append("the non-macOS release path never exports MavericksShipyard_DIR, so "
                   "find_package(MavericksShipyard) cannot resolve on a Linux runner (R-P1-23)")
    if not any(re.search(r'^\[ -f "\$root/MavericksShipyardConfig\.cmake" \] \|\|', c) for c in rel_oth):
        bad.append("the non-macOS release path exports MavericksShipyard_DIR without checking the "
                   "config is actually there; a wrong path would surface as a consumer's find_package failure")
    for pat, why in ((r'^sudo installer', "installs a pkg"),
                     (r'^gh release download', "downloads a release asset")):
        if any(re.search(pat, c) for c in rel_oth):
            bad.append("the non-macOS release path %s; there is no Linux pkg to install" % why)

# Only source: build may refuse a non-macOS runner -- it compiles CMake against an Apple toolchain.
if not any("exit 1" in c for c in cmds(lambda c: "'build'" in c and "runner.os != 'macOS'" in c)):
    bad.append("source: build no longer refuses a non-macOS runner, where it cannot build CMake at all")
# ...and nothing outside source: build may do so, which is the failure R-P1-18 exists to undo.
for c in cmds(lambda c: "'build'" not in c):
    if re.search(r'uname -s.*Darwin', c) and "exit 1" in c:
        bad.append("install@v1 fails on a non-macOS runner outside source: build (%s) -- R-P1-18: the "
                   "release path must hand those jobs shipyard's shell half instead" % c)

if not exports(bld, "SHIPYARD_SCRIPTS"):
    bad.append("build mode never exports SHIPYARD_SCRIPTS")
if not exports(bld, "SHIPYARD_CMAKE_TREE"):
    bad.append("build mode never exports SHIPYARD_CMAKE_TREE, which is what release.yml packages")
if not any(re.search(r'^echo "\$b" >> "\$GITHUB_PATH"$', c) for c in bld):
    bad.append("build mode never puts the shipyard-* commands on PATH")
if not any("inputs.cmake-tree" in c for c in bld):
    bad.append("build mode never reads the cmake-tree input (R-P1-19)")
if not any(re.search(r'^\[ -n "\$tree" \] \|\|', c) for c in bld):
    bad.append("build mode never refuses an empty cmake-tree; it would `cp -R` from nowhere and fail "
               "somewhere far from the caller that forgot to pass it")
# The tree goes to packaging UNTOUCHED: package-pkg.sh refuses a --cmake-tree with anything outside
# bin/doc/man/share, and the build-mode prefix has shipyard installed into it.
if any(re.search(r'SHIPYARD_CMAKE_TREE="?\$p', c) for c in bld):
    bad.append("SHIPYARD_CMAKE_TREE must be the untouched CMake tree, not the prefix shipyard was installed into")
if any("cmake/packages" in c for c in rel_mac + rel_oth + bld):
    bad.append("install@v1 still reads the CMake user package registry")
for b in bad: print("FAIL: " + b)
if bad: sys.exit(1)
print("ok: install@v1 installs the released pkg on macOS, hands non-macOS jobs the shell half, and source-builds only for shipyard")
PY
echo "PASS: shipyard-release-workflow"
