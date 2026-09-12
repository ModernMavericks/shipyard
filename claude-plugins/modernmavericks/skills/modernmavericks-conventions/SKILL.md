---
name: modernmavericks-conventions
description: Use when creating or modifying a ModernMavericks (mavericks-*) project — its release workflow, Renovate/automerge config, versioning, shipyard usage, or Sparkle updater — or when deciding whether a deviation from the family conventions is warranted.
---

# ModernMavericks project conventions

ModernMavericks repos (`mavericks-*`) each cross-build one upstream thing into a **Mac OS X 10.9
(Mavericks)**-compatible `.pkg` with a **Sparkle** auto-updater, on a modern Apple-Silicon runner,
with **no 10.9 build runner anywhere**. They share a CMake/Renovate helper (`ModernMavericks/shipyard`)
and a common release/versioning shape. This skill is the family's conventions plus the judgment calls
that copying one repo can't teach.

**Core rule: match the family unless the upstream or product genuinely differs — and when you deviate,
say so in a comment or PR describing why.** A silent deviation reads as a mistake; a documented one reads
as a decision.

## Canonical templates (copy these, not the others)

The family has an older/simpler variant and a current/mature variant. **Start from the mature one.**

| Copy from | For | Notes |
|---|---|---|
| **mavericks-golang** | the whole modern shape: `UPSTREAM_VERSION` + `build/version.sh`, green-gated `release.yml`, `renovate.json` | most complete reference |
| **mavericks-legacysupport** | the `version.sh`/`lib.sh`/`release-notes-file.sh` scripts verbatim | origin of the auto-cut pattern |
| swift-toolchain, swift-runtime | the **tag-only-publish** release model (see below) | when you don't auto-cut on main |

## shipyard: consume its facilities, never hand-roll them

- Install via its **action**: `uses: ModernMavericks/shipyard/.github/actions/install@v1`. It
  self-registers in the CMake user package registry; consume it downstream with `find_package` — **no
  `CMAKE_PREFIX_PATH`, no vendored copy, no hand-run `cmake --install`.**

  **Installing shipyard: the pkg, not `cmake --install`.** Download the `.pkg` from the latest release
  (`gh release download -R ModernMavericks/shipyard --pattern '*.pkg'`) and install it. It puts the
  payload in `/usr/local/mavericks-shipyard`, registers that location with whatever cmake is on your
  `PATH`, and installs a Sparkle updater that keeps it current — so an install can never quietly become
  a month old, which is exactly what happened before this existed.

  `cmake --install` is now for **developing shipyard itself**, not for consuming it. CI is unaffected:
  `install@v1` still builds from source and stamps the version it installs.

  If you install shipyard on a box with no cmake, the shell scripts still work and the CMake side is
  skipped with a message. Install a cmake — any cmake — then run
  `sh /usr/local/mavericks-shipyard/scripts/register-with-cmake.sh /usr/local/mavericks-shipyard`, or
  just wait for the next Sparkle update, which runs the same step.
- `@v1` is the **moving major tag**; Renovate's native github-actions manager tracks it — **no custom
  manager, no SHA pin, no marker comment** for it. It moves **automatically**: shipyard's `release.yml`
  runs on every push to `main`, derives the version from the committed line in `UPSTREAM_VERSION` plus
  the commit count (`scripts/shipyard-version.sh`), publishes a GitHub Release for the immutable
  `vX.Y.Z`, and fast-forwards `@v1` to that commit. So a shipyard change reaches consumers by **pushing
  `main`** — never move `@v1` by hand, and there's no separate "publish" step to run.
- **After `install@v1`, use `$SHIPYARD_SCRIPTS`** — the action exports the installed scripts dir. Do NOT
  re-derive it with `SH="$(cat "$HOME/.cmake/packages/MavericksShipyard/"* | head -1)/scripts"`;
  that incantation appeared 11 times across the family before it was exported once. (It remains valid
  — it is what the action itself reads — so adopting `$SHIPYARD_SCRIPTS` is per-repo, never a flag day.)
- Reuse a sibling checkout of shipyard locally; don't duplicate its logic.

**Pinning shipyard: `@v1` normally, `@vX.Y.Z` when you need to stand still.** `@v1` is a *moving*
tag — it advances on every push to shipyard's `main` and reaches every consumer within minutes, which
is what makes a shared fix propagate for free. The cost is that a bad shipyard reaches everyone just as
fast: on 2026-09-09 a defect in conventions check 7d reddened two repos within the hour.

Since shipyard cuts `vLINE.COUNT` on every push (`scripts/shipyard-version.sh`), every one of those
pushes is a real, downloadable, pinnable release. So when `@v1` breaks you and you cannot wait for a
fix, pin the previous version — `uses: ModernMavericks/shipyard/.github/workflows/family-conventions.yml@v1.0.<N>`,
where `<N>` is a real patch number from `gh release list -R ModernMavericks/shipyard` (pick the release
before the bad one) — and move back to `@v1` afterwards. Say why in the diff, so the pin has an exit.
Never copy a specific `<N>` from this doc: the count advances on every push to shipyard's `main`, so
any literal written here is stale by the time you read it — always look up the current one.

`gh release list -R ModernMavericks/shipyard` shows what is available;
`gh api repos/ModernMavericks/shipyard/git/ref/tags/v1 --jq .object.sha` says where `@v1` points now.

**Use its facilities for 10.9-correctness — do NOT reinvent SDK fetching, floors, build-mode handling,
updaters, signing, or compat checks:**

| Facility (CMake fn · script) | Does | Don't hand-roll |
|---|---|---|
| `mavericks_build_mode` · `MavericksMode` · `mavericks_mode.sh` | selects/asserts the build MODE: native-on-10.9 vs cross-on-modern | arch/host detection |
| `mavericks_fetch_sdk` · `fetch_sdk.sh` | the pinned, integrity-checked MacOSX10.9 SDK | fetching an SDK yourself |
| `RequireAppleClang` | enforces Apple `/usr/bin/clang` (cgo/ObjC) | assuming the toolchain |
| `mavericks_assert_binary_compatible` · `MavericksCompatGuard` · `assert_binary_compatible.sh` | proves a built binary is 10.9-safe (floor + symbol set) | a bespoke compat check |
| `mavericks_add_updater_app` · `MavericksSparkle` · `stage_updater.sh` | builds/stages the Sparkle updater (self-fetches the framework) | wiring Sparkle by hand |
| `set_install_floor.sh` | stamps the 10.9.5 install floor on the `.pkg` | editing the pkg Distribution |
| `sign_and_appcast.sh` · `gen_appcast.sh` | EdDSA-signs + renders the appcast (fetches `ed25519-sign` via `gh`) | rolling your own signing |
| `mavericks_fetch` · `mavericks_locate` | fetch / locate helpers | ad-hoc `curl` / paths |

## The build must also run natively ON 10.9

CI and day-to-day development happen on modern macOS, but a ModernMavericks product's build must
generally still work **natively on a real Mavericks box**, with occasional deliberate exceptions. That
is not sentiment: a native build is the check that the cross-build's inputs and assumptions are honest,
and it is how the family avoids depending on a runner it can never reproduce.

Practically, for anything a **native 10.9 build executes** — `versions.sh`, `version.sh`, the
`build/*.sh` chain, packaging:

- **POSIX `/bin/sh` only.** No bashisms; 10.9's `/bin/sh` is old.
- **Assume 10.9-vintage tools.** `patch` is Apple's 2.0 (it has `-F` fuzz, it does **not** have
  `--merge`). Do not assume GNU behaviour from coreutils flags — `sort -V` in particular is not
  something to rely on there.
- **No `python3`.** 10.9 ships Python 2 only.
- Prefer git plumbing and plain shell over anything that arrived with Homebrew.

Scripts that only ever run **in CI** (the conventions gate, release-notes generation, the publish path)
may use `python3`, `sort -V`, and modern tools freely — but say so, so the next person knows which side
of the line a script is on. When a script must work in both places, the 10.9 constraint wins.

## Build OUT of the source tree, onto fast local storage

**A family checkout may live on NFS, so never put a build directory under
`${sourceDir}`.** `~/Documents/code` is an NFS automount on the maintainer's
10.9 box; every `.o`, every link, and every test fixture written under the
source tree crosses the network.

Measured on macho-tools, same commit, same compiler, full configure + build:

| build directory | wall | CPU |
|---|---|---|
| local disk | **2.96s** | 88% |
| in-tree on NFS | **11.16s** | 25% |

User time was identical (1.78s vs 1.81s) — the entire 3.8x is I/O wait, which
is why the CPU figure collapses. It compounds: an agent-driven session runs
dozens of builds per task (one per commit, one per mutation test, one per
verification round), and the test suites compile fixtures and dylibs on every
run. This is the single cheapest speedup available to this family.

- **`CMakePresets.json` is committed and shared, so its `binaryDir` must stay
  portable.** Do NOT hardcode a developer's local path there, and do NOT use
  `${sourceDir}/build-*`.
- **`CMakeUserPresets.json` is the CMake-sanctioned per-developer override** —
  gitignore it, and have it inherit the shared preset while pointing
  `binaryDir` at local storage:
  ```json
  {"version": 6,
   "configurePresets": [
     {"name": "native-local", "inherits": "native",
      "binaryDir": "/private/tmp/build/$env{USER}/<repo>-native"}]}
  ```
  Preset names must be unique across both files, so a local preset takes a new
  name rather than shadowing the shared one.
- **Do not "fix" this with a symlink** at `${sourceDir}/build-native`. It works
  — CMake writes through it and the objects land locally — but a `.gitignore`
  entry written as `build-native/` (with the trailing slash) matches a
  DIRECTORY and NOT a symlink, so the link shows up as untracked and pollutes
  `git status` for everyone. Verified, not assumed.
- **CI is unaffected**: GitHub runners have local disks, so `${sourceDir}` is
  already fast there and the shared presets keep working unchanged.

## Build equivalence: native-10.9 ≡ modern-cross (core invariant)

The product must run on **10.9**, but **there is no 10.9 build runner in CI** — every project cross-builds
on a modern Mac. So each project MUST establish that its cross-build equals a native-10.9 build, via
shipyard's facilities rather than trusting the runner:

- Drive the build through the **mode** machinery (`mavericks_build_mode`) so native and cross are the same
  recipe against the same pinned 10.9 SDK and floor — not two divergent paths.
- **Gate on the compat guard** (`mavericks_assert_binary_compatible`): fail the build if any shipped binary
  declares a floor above 10.9 or links a symbol 10.9 lacks. This is the in-CI equivalence proof — every
  project needs it (or an equivalent gate), since no 10.9 runner validates the output.
  - **`MAVERICKS_REQUIRE_DEFINED_SYMBOLS` is product-specific — do NOT copy golang's blindly.** The guard
    already denies the common post-10.9 symbols (`_clock_gettime`, `_os_unfair_lock_*`, `_os_log*`, …) as
    *undefined imports* by default. `REQUIRE_DEFINED` is the opposite assertion — "this symbol MUST be
    **defined** in the binary" — and is meant ONLY for a product that deliberately *uses* a post-10.9 API
    and links a 10.9 backport shim that defines it: golang uses `clock_gettime` and ships
    macports-legacy-support, so it sets `REQUIRE_DEFINED='_clock_gettime'` to prove the shim got linked. A
    port that builds against the 10.9 SDK and takes the 10.9 fallback (most of them — e.g. openssh →
    `gettimeofday`) links **no** shim and must leave `REQUIRE_DEFINED` **empty**. Copying golang's value
    into such a repo makes the guard demand a shim that isn't there (every binary fails "required symbol
    not DEFINED"). Decide it from *your* build (do you link a legacy-support shim?), not from the template.
- Where a stronger proof fits, keep a **characterization reference**: commit a trusted native-10.9 artifact
  and compare the cross-build against it (magic-trackpad2's kext characterization), and/or an emulated
  smoke (golang's best-effort Rosetta self-test).
- Back it with **out-of-band re-validation on real 10.9 hardware** before trusting a release.

## Where family-authored 10.9 back-fills live (headers + polyfill symbols)

When a build needs a 10.9-missing symbol or header that neither the 10.9 SDK **nor**
`macports-legacy-support` provides, someone has to hand-author the back-fill. **It does NOT go into
`mavericks-legacysupport`.** That repo is a *clean port* of `macports/macports-legacy-support` — its
`UPSTREAM_VERSION` tracks the MacPorts tag and Renovate bumps it self-contained; adding our own code to
its shim forks the port and breaks that clean bump (the next upstream bump silently drops our addition).

**The golang `REQUIRE_DEFINED='_clock_gettime'` pattern is NOT a precedent for putting our code there.**
`clock_gettime` is defined by the **real upstream** macports-legacy-support, which genuinely carries it —
golang just *links the port*. Our *own* back-fill is a different thing (upstream doesn't have it) and
needs a different home. Three tiers, in order:

1. **Offer it to the real upstream** — `github.com/macports/macports-legacy-support` (the MacPorts
   project). This is the only true "upstreaming"; if accepted it reaches the whole family through the
   normal `mavericks-legacysupport` port bump, zero family maintenance. Best for a genuinely-general C
   symbol back-fill.
2. **`mavericks-compat`** — the family's home for its **own** 10.9 back-fills (header shims + a compiled
   `libMavericksCompat.a` of polyfill symbols); a **self-upstream** product (`YYYYMMDD.N`, no
   `-mavericks`). The **default** home for anything ours that isn't yet, or won't be, upstream. Consumers
   fetch its `.pkg` and link the `.a` / `-isystem` the headers, like any pinned ingredient. **Boundary:
   it carries ONLY what upstream does not** — when the port gains a symbol we carry, drop ours (a
   duplicate-symbol link error is the signal the boundary was violated). It builds its `.a` with the
   runner's stock clang + the pinned 10.9 SDK, **not** clang-22 (clang-22 consumes its headers, so
   depending on it would be a build cycle).
3. **Per-repo** — only a genuinely repo-specific quirk (a header one product's build alone needs),
   recorded in that repo's `INGREDIENTS.md` as a baked-in input. Not for anything another repo would want.

**Do NOT** hand-carry a generically-useful back-fill as a private `.c`/header per repo, and **do NOT**
put a linked runtime symbol in `shipyard` (it holds build facilities — CMake fns + scripts — not
runtime back-fills).

## Renovate & automerge

Consumer `renovate.json` is `{"$schema", "extends": ["github>ModernMavericks/shipyard"]}` plus
your upstream manager and rules. The shared preset provides `config:recommended` + `automerge: true`.

**The `ignoreTests` policy (load-bearing):** the preset now defaults **`ignoreTests: false`** — automerge
waits for a green build. That only works if **your repo produces a CI status check on Renovate PRs**:

- Give `release.yml` a `pull_request: branches: [main]` trigger (or `push: branches: ['**']`) so the
  build runs on the bump PR. This is what Renovate's automerge waits on.
- A repo with **no build to gate** must set `ignoreTests: true` locally (opt back into blind automerge)
  — this is the one legitimate use; shipyard itself does it.
- **Do not restate `ignoreTests: false` locally** — the preset sets it, and a local copy silently stops
  tracking the preset the day the preset changes. `check-family-conventions.sh` fails on it. Overriding
  with a *different* value (`true`, above) stays legal: that is a decision, not a duplicate.
- **For a green-gated PR to merge *promptly*, native auto-merge needs BOTH** (either alone is inert):
  1. the repo's **"Allow auto-merge"** enabled — off by GitHub default:
     `gh api -X PATCH repos/OWNER/REPO -f allow_auto_merge=true`; and
  2. **branch protection on `main` requiring the PR build check** — GitHub only *arms* auto-merge when a
     required check is pending. Set `strict:false` (no forced rebases) + `enforce_admins:false`
     (maintainers keep direct-push):
     ```sh
     printf '{"required_status_checks":{"strict":false,"contexts":["build"]},"enforce_admins":false,"required_pull_request_reviews":null,"restrictions":null}' \
       | gh api -X PUT repos/OWNER/REPO/branches/main/protection --input -
     ```
  The context is the build **job name** (`build`, `build-macos`, or a job's `name:` string like
  `Cross-build + compat gate (macos-26)`) — read the exact string from a real check-run first
  (`gh api repos/OWNER/REPO/commits/main/check-runs --jq '[.check_runs[].name]|unique'`); a typo requires a
  check that never reports and **blocks every merge**. Without the required check, `allow_auto_merge` is
  inert and the PR merges only on Renovate's next scan (still gated, just not instant).

**These two settings are the only conventions the gate cannot check — audit them.**
`check-family-conventions.sh` reads a checkout, so every rule it enforces is file-shaped. "Allow
auto-merge" and branch protection are GitHub repo state, reachable only through the API, and no
`renovate.json` preset can set them. They drifted exactly that way: four repos created 2026-08-02 to
08-04 had neither, so their Renovate bumps never merged — signal-desktop's Signal 8.26.0 sat green
and unmerged for a month with nothing anywhere going red.

Run `sh scripts/audit-repo-settings.sh` (needs `gh`, and admin — reading branch protection is
admin-only, which is why this is not a CI gate). It prints both settings for every product repo and
exits non-zero when a green bump could not merge.

**Read the required context from a real check-run, never by analogy.** The context is the build job
name, and the right one is a job that runs *on pull requests*. shipyard's own release job is named
`build` but its workflow is push-only, so requiring `build` there would have blocked every PR
forever; the PR-visible job is `test`, from `ci.yml`. Check first:
`gh api repos/OWNER/REPO/commits/main/check-runs --jq '[.check_runs[].name]|unique'`

**Every build ingredient must be able to auto-update — wire a customManager when the standard managers
don't reach it.** An ingredient nobody tracks goes stale silently and nothing reports it: swift-runtime
pinned `swift-toolchain` at `6.3.3-mavericks.1` while that repo shipped `.3`, for months, because
moving the pin meant a human fetching and pasting two SHA256s. `check-family-conventions.sh` fails an
`INGREDIENTS.md` row marked ❌ unless it says **untrackable**.

**A pinned hash is usually what blocks the bot.** A hash can only vouch for bytes someone has already
seen, so every bump needs a human to paste a new one — which is exactly the step automation cannot
take. Two ways out, both in use here:

- **Verify against upstream's own published `SHA256SUMS`** for the pinned release. That vouches for a
  version that does not exist yet, so Renovate only has to move the *ref*. container-tools does this
  for the golang toolchain; swift-runtime does it for the swift-toolchain build environment. Prefer
  this whenever the upstream is a ModernMavericks repo — `publish-release.yml` regenerates
  `SHA256SUMS` over everything it attaches, so the file is always there. Fail if the asset is **not
  listed**, rather than passing an empty expectation to `shasum` — unverified must never look like a
  pass.
- **Verify by signature** where upstream publishes no checksums file: swift-toolchain checks the
  swift.org `.pkg` against its **signer identity**, which is stable across releases.

**Derive, never repeat, anything computable from a pin.** `SWIFT_TAG="swift-${SWIFT_VERSION}-RELEASE"`,
not a second literal — Renovate rewrites one line, and a repeated value left behind builds something
other than what the pin names. Both swift repos learned this the same way.

**Automerge policy: if it builds and passes, it ships** — patch, minor **and** major alike. The build
is the gate (`ignoreTests: false`), and breakage that gets through is fixed forward in a
`-mavericks.N+1` release, which costs less than a human reviewing every routine bump. Most repos
therefore need **no `packageRules` at all**.

**Restrict automerge only where a bad bump would BUILD FINE AND BE WRONG** — the case a green build
cannot catch — and say so in the rule's `description`. `check-family-conventions.sh` fails an
automerge rule with no description: unexplained, an exception is indistinguishable from drift.

The live example: swift-toolchain gates minor/major Swift bumps because `LLVM_BRANCH` is
`swift/release/<minor>` and must follow, which no regex can infer; left alone it builds the new Swift
against the old LLVM build support and succeeds. By contrast golang needs no exception — a Go minor
bump hits `apply-patches.sh`, which hardcodes `patches/126/`, so the patches fail to apply and the PR
never merges.

**Manager rules** (what to track, not whether to automerge):

```json
"customManagers": [{
  "customType": "regex",
  "managerFilePatterns": ["/^UPSTREAM_VERSION$/"],
  "matchStrings": ["^(?<currentValue>.+?)\\s*$"],
  "depNameTemplate": "acme/foo",
  "datasourceTemplate": "github-tags",
  "extractVersionTemplate": "^v(?<version>.+)$"
}],
"packageRules": [
  {"matchDepNames": ["acme/foo"], "matchUpdateTypes": ["patch"], "automerge": true},
  {"matchDepNames": ["acme/foo"], "matchUpdateTypes": ["minor","major"], "automerge": false}
]
```

- Use **`managerFilePatterns`** (regex-delimited `"/^UPSTREAM_VERSION$/"`), not the deprecated `fileMatch`.
- Pick the datasource for how upstream ships: `github-tags` (+`extractVersionTemplate` to strip `v`),
  `golang-version`, `git-refs`/`currentDigest` for a raw commit, etc.
- Track the pin in a dedicated bare file (`UPSTREAM_VERSION` = `1.4.2`) matched whole-file, **or** an
  inline value carrying a marker comment (`… # mavericks-legacysupport`) when it lives in a shared file.
- **A pin on a sibling's `-mavericks.N` release needs versioning that compares N:**
  `"versioningTemplate": "regex:^(?<major>\\d+)\\.(?<minor>\\d+)\\.(?<patch>\\d+)-mavericks\\.(?<build>\\d+)$"`.
  Renovate's default versioning coerces the suffix away, so `.1` and `.4` compare **equal** and the bot
  proposes nothing — no PR, no error, and the Dashboard still lists the dep as tracked. swift-runtime's
  swift-toolchain pin sat at `6.3.3-mavericks.1` through `.2`, `.3` and `.4` this way, *after* its
  manager was wired. The shared preset's legacysupport manager and the golang consumers
  (container-tools, tailscale) already do this; `check-family-conventions.sh` fails a manager whose
  captured pin ends in `-mavericks.N` without it.

**This customManager is the release trigger** — it's how the package auto-updates when upstream does:
Renovate bumps the pin → the green-gated build merges → the workflow cuts the release. Author it to fit how
upstream publishes; if no standard datasource fits (a versioned download URL, a components file), write a
custom regex manager + the closest datasource (`git-refs`, a `custom.regex` match) — container-tools tracks
a `components/*/version` file this way. **GitHub Actions pins** (`uses: …@vN`, including `shipyard/…@v1`)
need no custom config: Renovate's built-in github-actions manager updates them through the same green-gate +
patch-automerge — that's the intended auto-update for the workflow's actions.

## Contributor access: who may push to `main`

A green-gated `main` (above) changes what "giving someone access" means: **the Write role is not
direct-push to `main`.** A Write collaborator can push branches and open/merge PRs, but a *direct*
push to `main` is rejected — the required check is unmet and they are not exempt. Direct push is a
separate, deliberate grant. Decide per person:

- **Gated contributor (the default — use it for outside contributors).** Grant Write; they work
  branch → PR → green build → merge (auto-merge lands it once green). Their changes stay behind the
  build gate.
  ```sh
  gh api -X PUT repos/OWNER/REPO/collaborators/USER -f permission=push   # invite at Write
  ```
- **Direct-push contributor.** They must be **exempt from the required check**, and *how* depends on
  which protection `main` uses:
  - **Ruleset** (org- or repo-level; the tell is a push that reports *"bypassed rule violations"*):
    add them to the ruleset's **bypass list**. Least privilege: give the **Maintain** role a bypass
    entry with mode **Always**, then grant Maintain — not admin.
    ```sh
    gh api -X PUT repos/OWNER/REPO/collaborators/USER -f permission=maintain
    gh api orgs/ORG/rulesets --jq '.[] | "\(.id)\t\(.name)"'   # find the ruleset id (needs admin:org)
    gh api orgs/ORG/rulesets/<id> --jq '.bypass_actors'        # inspect the bypass list, then ADD a
    #   Maintain-role entry (mode Always) via Settings → Rules, or PATCH this ruleset's bypass_actors
    ```
  - **Classic branch protection** (`…/branches/main/protection` with `enforce_admins:false`, above):
    admins are already exempt, so granting **Admin** gives direct push — that is the "maintainers keep
    direct-push" this doc means.
- **Bypass mode is load-bearing:** **Always** = may push straight to `main`; **For pull requests only**
  = may only bypass a *PR merge*, never a raw push.
- **Org rulesets are org-wide:** editing the bypass list changes `main` across every `mavericks-*` repo
  unless the ruleset is scoped; use a repo-level ruleset for per-repo control.
- **The trade-off:** adding someone to bypass removes the build gate for *their own* direct commits —
  the protection you just built. Default to Write + PR; reserve bypass/admin for trusted maintainers.

## Product naming

Two registers, so the app reads as a recognizable "Mavericks ___" product while longer strings stay
natural (and, for a repackaged third-party product, nominative rather than co-branded):

- **App identity — "Mavericks Foo"** (brand-forward, discoverable, matches the `mavericks-foo` repo name).
  Use for: the `.app` bundle filename, `CFBundleName`/`CFBundleDisplayName`, the Sparkle updater
  `PRODUCT_NAME` (drives "A new version of ___ is available"), and the updater `CONFIRM_TITLE`.
- **Prose / longer strings — "Foo for Mavericks"** (descriptive; reads as "the real Foo, for the
  Mavericks OS"). Use for: the `.pkg` installer `--title`, the appcast `--channel-title`, README prose,
  and release notes.

"Mavericks" here is the **OS** (10.9), so "Mavericks Tailscale" = "the Mavericks build of Tailscale" —
which helps rather than hurts on the trademark front; keep the "unofficial community build, not affiliated
with <upstream>" disclaimer regardless. Where the product name is a third-party trademark used
nominatively (Tailscale), this is fine; where you can't use the upstream noun at all (Docker → "Container
Tools"), the descriptor already IS your name, so "Mavericks Container Tools" is simply your product line.

Never rename **functional identifiers** to match: bundle IDs (`dev.modernmavericks.*`), executable names,
`launchd` labels, `hostinfo.SetPackage`/equivalent, internal helper bundles (e.g. the `*Updater.app`), and
asset filenames stay as they are. A `.app` name with a space is fine; quote the path in shell/plists.

## Versioning

**First decide: does this repo PORT an external upstream, or is it its OWN upstream?** The `-mavericks.N`
suffix means "our Nth repackage of *someone else's* thing." Most repos port an upstream and use the
`<upstream>-mavericks.N` machinery below (including date-versioned ports — `mavericks-ed25519`
`20221003-mavericks.N`, `mavericks-container-tools` `20260727-mavericks.N` — where `UPSTREAM_VERSION` is a
date but they are still repackaging an upstream). A repo that is **its own upstream** — original
ModernMavericks code, not a port (e.g. `mavericks-porthole`) — has no "repackage-of-someone-else" axis, so
it **drops the `-mavericks` suffix** and versions itself directly:

- **date-based `YYYYMMDD.N`** (`mavericks-porthole`; N counts the day's releases starting at `.1`, never
  omitted) — the family's date form but *without* `-mavericks`, precisely because it is not a port;
- **semver `vX.Y.Z`**, or dimmit's `v0.0.YYYYMMDD.N`.

Mechanics for a self-upstream repo: `UPSTREAM_VERSION` (if used) is the repo's OWN version/date,
hand-bumped (no Renovate datasource — nothing external to track). There is **no `resolve-version.sh`** (it
hardcodes `-mavericks.`), so `release.yml` computes the version itself (e.g. `<date>.N` from the existing
`<date>.*` tags, `fetch-depth: 0`). `VERSION` stays a gitignored build product; the family-conventions
gate still applies unchanged (committed `UPSTREAM_VERSION` + uncommitted `VERSION` passes it), and you
still publish via `publish-release.yml@v1`. **Everything below — the two bump axes, `resolve-version.sh`,
`build/version.sh`, the `-mavericks.N` suffix — is for the PORT case.**

**Two independent bump axes.** The **upstream component** moves when upstream releases: Renovate edits
`UPSTREAM_VERSION`, and `version.sh auto` cuts `<new>-mavericks.1` (N resets to 1). The **`-mavericks.N`
suffix** moves for a packaging-only re-release (recipe/patch/updater/CA change, upstream unchanged): via
`workflow_dispatch local_release=true`, which cuts N+1. Never hand-edit `VERSION` for either — it's computed.

- **`UPSTREAM_VERSION`** — committed, bare (`1.4.2`, no `v`), Renovate-edits it. Read by `build/lib.sh`'s
  `upstream_version()`.
- **`VERSION`** — `<upstream>-mavericks.N`, **a BUILD PRODUCT**: gitignored (`/VERSION`), written by
  `resolve-version.sh`, never committed. `check-family-conventions.sh` fails a *tracked* one. In CMake
  use `mavericks_resolve_version(MYVAR)` (from the package Config, so plain `find_package` is enough —
  no `include(Mavericks)` needed) rather than `file(STRINGS VERSION …)`, which only ever worked because
  four repos committed the file.
- **`scripts/resolve-version.sh [auto|local]`** — the one way to learn the version at build time. It
  reuses an existing `VERSION` so **every job in one run agrees**, and derives+writes one otherwise.
  An empty `VERSION` fails loudly: artifacts named `-mavericks.` with nothing in front look almost right.
- **`scripts/release-mode.sh`** — answers "is this run a repackage?" once, from the event. Every job
  that resolves a version must use it. container-tools built one `.pkg` from two jobs that disagreed —
  `build-macos` resolved `-mavericks.15`, `build-iso` resolved `.14`, same run, same commit — because
  a parallel job has no way to know a repackage is in progress. Making one job `needs:` the other fixes
  it by serialising builds that have no reason to wait; a shared decision does not.
- **Any job that resolves a version needs `fetch-depth: 0`** — N comes from the tags. Without them CI
  labels every build `-mavericks.1` and hides what it is really building.
- **Where the upstream comes from a pin rather than a committed file**, the repo has
  `build/derive-upstream-version.sh` or `scripts/derive-upstream-version.sh` writing `UPSTREAM_VERSION`
  (ed25519: the pinned commit's date; tailscale: upstream's own `VERSION.txt`; the swift repos: their
  `SWIFT_VERSION` pin). It must run **before anything configures CMake**.
- **`build/version.sh <auto|local>`** computes the full version + release decision (copy verbatim):
  `auto` → N=1/`RELEASE=yes` for a new upstream (no tag yet), else current N/`RELEASE=no`;
  `local` → N=max+1/`RELEASE=yes` (a packaging-only repackage). N resets to 1 whenever `UPSTREAM_VERSION`
  changes. Emits `FULL=`/`TAG=`/`RELEASE=` lines.
- Scripts derive `REPO_ROOT` themselves and source `lib.sh`; `versions.sh` reads `GO_VERSION`-equivalent
  from `UPSTREAM_VERSION` and falls back to `version.sh auto` when `VERSION` is absent (so a fresh checkout
  builds without a committed `VERSION`).
- **Repackage ownership can be declared by KEY, not just by path**: `own-upstream-paths:
  "pins.env:SWIFT_VERSION"`. Use it when a repo keeps its own-upstream pin and its ingredient pins in
  one file — declaring the whole file own-upstream skips every repackage, and declaring it not-own
  publishes twice (`-mavericks.1` from the push, `.2` from the dispatched repackage).
- **A test that encodes the upstream version MUST read it from `UPSTREAM_VERSION`, never hardcode** — a
  hardcoded version fails its own CI on the next Renovate bump and blocks the automerge.
- **When upstream ships several concurrently-supported lines** users want independently (Go minors,
  Node majors), don't fold them into one `UPSTREAM_VERSION` — carry each as a track under `lines/`.
  See the next section.

## Multiple upstream lines (tracks)

Most ports carry ONE upstream and its users always want the latest — a single `UPSTREAM_VERSION` is
right, and this whole section does not apply. But some upstreams support **several lines at once**
that users legitimately pin to independently — Go minors (`1.26.x`, `1.27.x`), Node majors (`24.x`,
`26.x`), an LLVM release series. For those, **a line is a product**: golang proved this shape,
nodejs is its first conformer. The rule is small; the drift it prevents is not.

**`lines/<id>/` holds ONLY that line's `UPSTREAM_VERSION` and `patches/`.** Everything else — install
prefix, pkg identifier, product title, and (load-bearing) the **Sparkle feed** — is *derived* from
the line id, never stored per line. `build/*` scripts stay line-invariant and take the line via an
env var (`GO_LINE`, `NODE_LINE`); only per-line *data* lives under `lines/`. A repo that cannot
express a per-line difference in one place cannot drift into an inconsistent one.

- **The point is the per-line feed: an installed updater NEVER crosses lines.** A 1.26 user is not
  carried onto 1.27, and a 1.26.7 published *after* 1.27.0 disturbs nothing. Each line has its own
  appcast/feed (`feed-126`, `feed-24`), and its release tag embeds the **full** upstream version
  (`1.26.5-mavericks.1`, `24.6.0-mavericks.1`) so lines never collide on a tag. `-mavericks.N` is
  counted per upstream version, so each line's N advances on its own.
- **One CAPPED Renovate manager per line.** Each `lines/<id>/UPSTREAM_VERSION` gets its own
  `customManager` whose `depNameTemplate` is line-specific, plus a cap (`allowedVersions: "<1.27"` /
  `"<25"`) so the line never walks onto a version it was not built for. This is a *cap*, not an
  automerge exception — ship-if-green still applies within the line. A new line arrives as a **new
  `lines/` dir with its own manager**, never by moving an existing pin. One manager spanning multiple
  lines is wrong: a single `allowedVersions` cannot cap each line.
- **Adding a line = 3 files:** `lines/<id>/UPSTREAM_VERSION`, its capped manager, and the line's path
  in the repackage caller's `own-upstream-paths`. Patches are optional — with none, fall back to the
  newest lower line's patches and apply with fuzz, giving a new line a real chance to just work; if
  the gates (compat guard, trust/characterization tests) catch a bad fuzzy apply, write
  `lines/<id>/patches/`. **Never relax the gates to make a new line green** — a fuzzy apply can
  succeed and be wrong, which is exactly what the gates exist to catch.
- **CI is plan→matrix.** Decide the whole release plan ONCE in a `plan` job that walks `lines/*/` and
  emits, per line, `{version, publish?}` — because a matrix job's outputs are last-writer-wins and
  GitHub hides the matrix context from a job-level `if`. The build job matrixes over lines with
  `fail-fast: false` (one line's breakage must not cancel another's). On a tag, the tag's embedded
  upstream version names **exactly one** line to publish; the others only build.
- **Side-by-side coexistence FORCES per-line functional identifiers.** If two lines install at once
  (versioned prefixes — `/usr/local/go126`, `/usr/local/node24`), their pkg receipts, updater bundle
  ids, and LaunchAgent labels must be per-line or they collide. This *refines* "never rename
  functional identifiers" (Product naming): the identifier is stable **per line**, and the line
  suffix is a coexistence necessity, not co-branding — record it in `INGREDIENTS.md`/conformance
  deviations. A repo that installs one line at a time may keep stock paths and rely on the per-line
  feed alone.

## Pushing is a request for CI feedback, not a save button

Since no branch push supersedes another (see `concurrency` below), **every push you make builds to
completion** across a family of macOS runners — and in the eight auto-cut repos a push to `main` may also
cut and publish a release. Pushing is therefore a decision, not a reflex.

- **Push when you want the answer**, not every time you have a commit. A series of commits is one push.
  Local commits cost nothing; a push costs runner minutes and everyone's feedback latency.
- **Look at what is already running first.** `gh run list --branch main --limit 5` (add `-R
  ModernMavericks/<repo>` from elsewhere). Queuing another build behind three in-flight ones delays the
  answer you actually came for.
- **Before pushing to `main` in an auto-cut repo, know whether this push releases.** If `UPSTREAM_VERSION`
  has no release yet, it does.
- This is also why an empty "probe" commit is a real cost. Use one when you genuinely need to see CI
  behave; delete the branch after.

## Release workflow

Two release models — **pick by how you publish**:

- **Auto-cut on main** — a push to `main` whose upstream has no release yet cuts
  `<upstream>-mavericks.1` by itself. The publish decision lives in the build job
  (`steps.ver.outputs.release`). Use this when Renovate merging the bump should *itself* release.
- **Deliberate publish** — build and gate on every push/PR, but publish only from an explicit tag or a
  `workflow_dispatch`. Use this when a human decides when to cut, or the build is too heavy or too risky
  to release unattended.

**Which repo is which** (checked 2026-09-09; each repo's `release.yml` header is the authority):

| auto-cut on a push to `main` | publishes only from a tag or a dispatch |
|---|---|
| golang, openssh, 1password, signal-desktop, swift-toolchain, swift-runtime, ed25519, legacysupport | macho-tools, container-tools, clang, tailscale, porthole |

If you cannot say from memory which column a repo is in, read its `release.yml` header before you push to
its `main` — in the left column, that push is a release.

**Shared shape (both models):**

- Three entry points: `push: branches:[main] + tags:['*-mavericks.*']`, `pull_request: branches:[main]`
  (the automerge gate), `workflow_dispatch` with a `local_release` boolean (repackage escape hatch).
- `checkout` with `fetch-depth: 0` (version.sh counts tags).
- A **`ver` step** (id `ver`) that: on a tag, takes `full=tag=$GITHUB_REF_NAME`, `rel=yes`; else runs
  `version.sh auto|local`, then **forces `rel=no` when `$GITHUB_REF_NAME != main`** (so PRs and non-main
  branches never publish); writes `VERSION`; sets outputs `full`/`tag`/`release`.
- **`gh release create "$TAG" dist/* …` mints the tag itself** — no `git tag`/push, **no PAT**. A
  `GITHUB_TOKEN`-created tag can't retrigger the workflow, so no second-hop/loop. (Don't reach for
  `softprops/action-gh-release` + a PAT; `gh release create` is the family way.)
- **`concurrency` — a run that can publish is alone in its group and is cancelled by nothing.** Only a
  `pull_request` supersedes, keyed per ref so a force-push replaces its own predecessor. Everything else —
  a branch push, a `*-mavericks.*` tag, a `workflow_dispatch` — is keyed on `github.run_id`, which puts it
  in a group of one: never queued, never evicted, never cancelled.
  ```yaml
  concurrency:
    group: >-
      release-${{ github.event_name == 'pull_request' && github.ref || github.run_id }}
    cancel-in-progress: ${{ github.event_name == 'pull_request' }}
  ```
  **`cancel-in-progress: false` was never the protection it looked like.** It protects the run that is
  EXECUTING and not one that is QUEUED: GitHub keeps only the newest pending run per group and cancels the
  rest. So the old shape — one shared group, `cancel-in-progress: false`, sold as a version-bump lock —
  silently discarded runs. mavericks-golang lost one on 2026-09-09, 13 seconds after the run that evicted
  it. Reproduced deliberately with a throwaway probe: two same-SHA dispatches merely queue, and the *third*
  cancels the queued one while `cancel-in-progress` evaluates to `false`. A lock that only holds for two is
  not a lock.
- **Nothing replaced that lock, and nothing needed to.** Two dispatches can now compute the same
  `-mavericks.(N+1)`; both build, and shipyard's `publish-release.yml` refuses the loser at publish time
  with a message naming the tag. A wasted build with a red X beats a release that silently never happened.
  The version is baked into `pkgbuild --version`, the pkg filename and the appcast's `<sparkle:version>`,
  so a collision must **rebuild** — re-dispatch — and must never be relabeled.
- **Why branch pushes do not supersede, even though superseding would be cheaper.** In 8 of the 13 product
  repos a push to `main` can publish (see the table above). Concurrency is resolved when a run is queued,
  long before the `ver` step decides whether this one releases, so "cancel the build but not the publish"
  is not expressible — cancelling the run cancels the publish job with it. Worst case that leaves a
  half-uploaded release whose tag is already taken, which the publish guard then refuses to re-cut. Paying
  for every main build is the cheaper mistake. `check-family-conventions.sh` check 1b enforces both
  halves: the group must be keyed on `github.run_id`, and `cancel-in-progress` must name
  `pull_request`. Either one alone lets the old shape back in — it mentions `github.event_name`, so a
  gate that only asks "does the group distinguish events?" waves it straight through.
- Sign/appcast and publish steps gate on `steps.ver.outputs.release == 'yes'`. Fork PRs never touch
  `SPARKLE_PRIVATE_KEY` (they resolve `release=no`).
- Runner `macos-26` (fallback `macos-15`); `actions/*@v7` on new repos.

## Version scaffolding (shared, wrapped)

- **`version.sh`, `lib.sh`, and `release-notes-file.sh` live in shipyard.** A repo carries only
  thin wrappers: `build/msc.sh` locates the installed scripts (`$SHIPYARD_SCRIPTS` → CMake user package
  registry → sibling checkout), and `build/version.sh` / `build/release-notes-file.sh` exec the shared
  implementation. Only the product name passed to the notes builder is genuinely per-repo.
- Wrapping rather than deleting keeps every call site working: `sh build/version.sh auto` on a dev
  box, the repo's own tests, `versions.sh`, and the release workflow.
- **`$MAVERICKS_ROOT` is the family-wide root variable** the shared logic reads. The wrapper sets it
  from its own location (a wrapper knows its repo definitively); `lib.sh` only defaults it, since it
  may be sourced where the root is already established. Repo-specific helpers go in the repo's
  `lib.sh` *after* sourcing the shared one — never as a copy of a shared function.
- **Install shipyard before computing the version** in CI: the wrapper needs `$SHIPYARD_SCRIPTS`.
- If a repo's test copies `build/` into a temp dir, copy **all** of `build/*.sh`. Cherry-picking a
  named subset silently breaks a wrapper that sources `msc.sh` — it caught two repos.

## Publishing a release

- **Publish with the shared workflow, never by hand.** A publish job is:
  ```yaml
  publish:
    needs: [build]
    if: needs.build.outputs.publish == 'true'
    permissions: { contents: write }
    uses: ModernMavericks/shipyard/.github/workflows/publish-release.yml@v1
    with: { version: "${{ needs.build.outputs.version }}", artifact: <artifact name> }
  ```
- Put the assets **and** `RELEASE_NOTES.md` in that artifact. The workflow regenerates `SHA256SUMS`
  (so drop any local `shasum` step), uses the notes as the Release body, and **fails if the notes are
  missing or empty**. An empty body is not a degraded release, it is the defect this removes: tailscale
  shipped one on every release — including hand-tagged ones that had a committed notes file — and
  swift-runtime set no body at all, because that wiring was per-repo.
- It publishes with `action-gh-release` (`tag_name` + `target_commitish`), which mints the tag inline.
  The dispatch-cut repos need that: a `GITHUB_TOKEN`-pushed tag triggers nothing.
- **A failed upload must not strand a draft.** `action-gh-release` creates the release as a *draft*,
  uploads, and publishes (minting the tag) only once every upload succeeds — and it does not retry a
  failed upload. golang's `1.26.8-mavericks.3` lost one `.pkg` to `other side closed` and sat as a
  tagless draft: invisible to Renovate, the appcast and every sibling, its ingredient bump unshipped,
  with only a red run to show for it. So `publish-release.yml` makes three attempts, deleting this
  tag's draft before each retry (`delete-draft-release.sh`: drafts of exactly this tag, never a
  published release), and deletes it after the last failure too. **Recovery is "Re-run failed jobs"**
  — the build artifacts are kept and the tag is still free — unless the caller's `main` gained a
  workflow change since the run started (the tag then 403s; re-dispatch).
- **An existing tag refuses the publish — except the tag that triggered the run.** Two runs can compute
  the same `-mavericks.(N+1)` and both build it; the loser must not publish and must not relabel (the
  version is already baked into the pkg and the appcast), so it re-dispatches. But a run started by a
  pushed tag always finds its own tag, and blanket refusal made the documented "publish from a tag"
  model impossible — clang had no working release path at all. `assert_tag_publishable.sh` allows
  exactly that case: the run's ref IS this version's tag, and the tag names the commit being published.

## Release notes

- **One generator: `$SHIPYARD_SCRIPTS/release-notes.sh`.** It writes the ONE file that becomes both
  the Sparkle appcast `<description>` and the GitHub Release body, so the two cannot disagree:
  ```sh
  sh "$SHIPYARD_SCRIPTS/release-notes.sh" --tag "$TAG" --version "$FULL" \
     --product OpenSSH --min-os 10.9.5 --out dist/RELEASE_NOTES.md
  ```
  `--product` is the BARE product noun; the script composes the family's prose register
  (`## OpenSSH 9.9p2 for Mavericks (9.9p2-mavericks.6)`, and `## Porthole 20260802.6` for a
  self-upstream product that is its own upstream). `--min-os` emits the install-floor line — omit it
  for a product that is not a 10.9 `.pkg`. `--line` scopes the baseline for a repo shipping parallel
  lines (golang's `1.26`); it is normalized internally, so both `1.26` and `1.26.*` work.
  `release-notes-file.sh` forwards it too, from `MAVERICKS_NOTES_LINE` in the environment (its
  positional signature stays `<TAG> <FULL_VERSION> [PRODUCT_NAME]`, so a line can't be a new argument).
  The generator `cd`s to the repo root before it runs, so **`--out` resolves against the repo root**,
  not the caller's cwd — a relative path from a subdirectory (a `build/` step, say) will not land where
  you typed it; pass an absolute path or one rooted at `$MAVERICKS_ROOT` from anywhere but the root.
- **The shape, in order:** title, the committed `release-notes/<TAG>.md` prose verbatim when present,
  `### What changed`, `### Build ingredients` when a pin moved, then a footer (the floor line, a
  compare link). Prose stays optional and is never rewritten; a release with none still says what
  changed — `release-notes-file.sh` is now a thin back-compat wrapper onto the generator, so the six
  repos still calling its old signature get the standard body before they migrate. **Committed prose
  must NOT carry its own `## ` title** — the generator emits the title itself and slots the prose
  verbatim right after it, so a note beginning with `##` produces two titles (golang's committed notes
  do this today; the family's per-repo `release-notes/README.md` files still describe the old
  convention where the note supplied its own title — a later plan updates them).
- **Every gap is FATAL, and names its cause.** Notes used to be prose that must never fail a release,
  so every generated fragment was appended with `|| true` and `2>/dev/null` — which meant a broken
  hook, an unreadable pin, or a shallow checkout produced a *shorter* body and a green run. openssh
  never listed a moved ingredient in any release (its comparison key skipped every `9.9p2` tag —
  see `comparison_key()` below), and signal-desktop shipped a new upstream with no link. Fatal now: no
  visible tags when the version implies an earlier release exists (a shallow or tagless checkout
  cannot decide new-upstream vs. repackage), a new upstream whose hook is missing (unless
  `INGREDIENTS.md` declares `No upstream release notes: <reason>`) or broken, a repackage caller whose
  ingredient pins cannot be read, an ambiguous caller (the conventional-path workflow isn't the one
  calling `repackage-on-ingredient-bump.yml`, and more than one other workflow does), an empty result.
- **`check-release-notes.sh <file> <version>`** asserts that shape: a title naming this exact version,
  a `### What changed`, no empty section, a non-empty body. The generator self-checks what it just
  wrote with it; `publish-release.yml` will check what it is about to publish with it too, once that
  enforcement lands.
- **`comparison_key()` in `lib.sh` is the one Sparkle-comparable-version derivation**
  (`-mavericks.N` → `.N`, and OpenSSH-portable's `9.9p2` → `9.9.2`), now shared by `gen_appcast.sh` and
  `previous-release-tag.sh`. Its absence from the latter is why no openssh release ever listed a moved
  ingredient — the appcast's `<sparkle:version>` folded `p2` and found a baseline; the notes generator's
  own numeric comparison didn't, and silently found none.

### A new upstream links upstream's own notes

A `-mavericks.1` exists to deliver someone else's changes, so its notes must say where to read them —
naming the new version is not enough. **Every port repo carries `build/upstream-release-notes-url.sh
<upstream-version>`** (in `scripts/` instead, where the repo keeps its scripts there — the swift repos),
which prints ONE URL: upstream's notes for exactly that version (the bare upstream version, `1.102.3`,
not the `-mavericks.N` tag).

- **Shipyard turns it into a `### What changed` bullet; the repo only answers "where".**
  `release-notes.sh` calls this hook through `upstream-notes.sh --url-only`, whose exit code says
  whether a missing link is due (3 = a repackage), absent (4 = no hook) or broken (5 = tags unknowable
  or the hook itself failed) — it decides whether a link is DUE before it even looks for the hook, so
  a repackage never needs one to exist. Only 3 is benign; the generator turns 4 with no declared
  reason, and 5, into a stopped release. A repo not yet calling the generator can still get the older
  standalone `### Upstream` section by calling `sh "$SHIPYARD_SCRIPTS/upstream-notes.sh" "$VER"`
  (no `--url-only`) and appending what it prints (tailscale's `release.yml`).
- **Only for a NEW upstream.** `upstream-notes.sh` links when no *other* `<upstream>-mavericks.*` tag
  exists, so a repackage gets nothing. It decides from the tags rather than the previous release,
  because with parallel lines the previous release can be another line's. A shallow clone or a repo
  whose tags it cannot list gets no section and a warning — never a false "new" — so the notes job
  needs `fetch-depth: 0`.
- **Usually one `printf`.** When upstream addresses its notes by version, that is the whole hook:
  ```sh
  #!/bin/sh
  # Upstream Go's release notes for one version; shipyard's upstream-notes.sh links them.
  set -eu
  printf 'https://go.dev/doc/devel/release#go%s\n' "${1:?usage: upstream-release-notes-url.sh <upstream-version>}"
  ```
  Put the tag shape in the format string (`releases/tag/llvmorg-%s`, `releases/tag/v%s`). Check that
  the URL — and its `#anchor`, if it has one — really exists for the current pin before committing it.
- **Link what a reader can actually read.** A GitHub release page with an empty body is a link to
  nothing: Swift publishes no notes for patch releases, so the swift repos link `CHANGELOG.md` at the
  release tag instead. An upstream with no releases at all links the pinned commit's history
  (ed25519: `commits/<UPSTREAM_COMMIT>` — the hook may read the repo's own pin, since a commit date
  cannot be mapped back to a commit).
- **No hook? Say why, in `INGREDIENTS.md`:** a line `No upstream release notes: <reason>`. That is
  every repo that is its **own** upstream (porthole, macho-tools, shipyard) and a port with no single
  upstream to point at (container-tools bundles six components, each an ingredient). A missing hook
  with no stated reason reads as a repo that never adopted this, and `check-family-conventions.sh`
  fails it — as it fails a hook that exists but is **not committed** (macports-legacy-support's
  `.gitignore` ignores `build/`, so `git add -A` skipped its hook silently; it is force-added, like the
  repo's other `build/*.sh`).
- **A script, not a URL template, because some upstreams cannot be addressed by version.** Tailscale's
  changelog is anchored by *date* (`#2026-08-19-client`), so its hook fetches the page, finds the
  client entry titled exactly `Tailscale v<version>`, and links that anchor. A hook like that: stays
  10.9-safe sh (BWK awk — it runs wherever notes are generated); is tested against a **fixture** of the
  real page, not the network; and when it cannot find the specific entry (no entry for that release,
  page unreachable) prints a less specific but working URL and says why on stderr.
- **Never fails a release.** No hook, a failing hook, or output that is not exactly one `http(s)` URL
  → no section, a warning on stderr. Notes are prose.
- `gen_appcast.sh` renders `[text](scheme:url)` and `### ` headings for the Sparkle `<description>`;
  write notes links in that form, not as bare URLs.

## Consuming a ModernMavericks toolchain + auto-propagation

A repo built WITH another MM product (e.g. the go126 toolchain) pins it in a **file** (not workflow env),
e.g. `components/golang/version`, tracked by a Renovate customManager (`github-releases` on
`ModernMavericks/golang`). Renovate bumps the pin; the green-gated build rebuilds the product with the new
toolchain and automerges. Two things to wire deliberately:

- **Download the toolchain asset prefix-tolerantly.** golang's cross `.pkg` was renamed `go126-` →
  `golang-` at 1.26.5-mavericks.1. Read the pinned release's `SHA256SUMS` and accept EITHER prefix (try
  `golang-…`, fall back to `go126-…`) so a pin bump across the rename never 404s.
- **Auto-propagation via the shared reusable workflow (dispatch, NOT tag).** A toolchain bump alone does
  NOT auto-cut a consumer release: the consumer's own auto-cut is driven by ITS upstream (N=1), not a
  dependency. To ship the rebuilt product automatically, add a ~10-line caller:
  ```yaml
  on: { push: { branches: [main], paths: [ <ingredient pin files, e.g. components/golang/version> ] } }
  jobs:
    repackage:
      permissions: { actions: write }   # dispatch release.yml — reusable perms can't be elevated by the callee
      uses: ModernMavericks/shipyard/.github/workflows/repackage-on-ingredient-bump.yml@v1
      with: { own-upstream-paths: <path(s) meaning a NEW own upstream → N=1, excluded; omit if none> }
  ```
  The reusable workflow decides "ingredient changed and not the own upstream?" and, if so, **dispatches**
  the consumer's `release.yml` via `gh workflow run … -f local_release=true`. It does NOT push a tag: a
  `GITHUB_TOKEN`-pushed tag can't trigger `release.yml` (GitHub's recursion guard), whereas
  `workflow_dispatch` IS `GITHUB_TOKEN`-triggerable. So the consumer's `release.yml` needs a
  `workflow_dispatch` `local_release` input that computes `-mavericks.(N+1)` and **publishes inline** in
  that same run (golang/legacysupport have it via `version.sh local`; tag-only repos must add it — the same
  fix repairs any `release-on-bump.yml` that relies on a pushed tag). CI-only bumps (`.github/**` action
  `uses:`) aren't in the caller's `paths:`, so they never repackage. This automates the `-mavericks.N` axis,
  driven by a dependency instead of a hand-run `local_release`.
- **In a committed-`VERSION` repo, derive the repackage's N from TAGS, not from `VERSION`.** A
  dispatch-cut version is published without being committed back (the tag is minted by
  `action-gh-release` via `tag_name` + `target_commitish`), so reading N from the file recomputes the
  same N+1 on the next ingredient bump and **overwrites that release** instead of cutting the next one.
  Take the highest existing `<upstream>-mavericks.*` tag (needs `fetch-depth: 0`) — idempotent, no
  commit-back. Repos deriving from tags already (`version.sh local`) are fine by construction.
- **Say which ingredient moved.** A repackage exists to ship a new input, so its notes must name that
  input — "rebuilt with the current ingredients (see components/)" tells a reader nothing.
  `ingredient-notes.sh <prev-tag> <pin>...` renders `- **name**: old -> new` for whole-file pins,
  per-key bullets for `KEY=VALUE` pins (literals only — a rewritten `$(...)` is a code change, not an
  ingredient change — and it reports keys that were *removed*), subject + `+N/-M lines` for `*.patch`
  pins (a patch is baked into the product, and a byte count says nothing about one), and a size delta
  for other opaque blobs.
  `previous-release-tag.sh` supplies the baseline (`sort -V`, so 1.102.0 > 1.98.8) and
  `ingredient-pins.sh` the pin list — **derived from the caller's own `paths:` minus
  `own-upstream-paths`**, so the repackage trigger and the notes cannot drift. Append the section to the
  notes file and publish that ONE file as both the appcast `--notes-file` and the Release `body_path`
  (an empty Release body is easy to ship without noticing — tailscale did, for every release).
  `check-ingredient-pins.sh` in CI fails a declaration whose globs match nothing. Notes are prose:
  every call site uses `|| true`, but warn on stderr rather than dropping the section in silence.
- **Track every trackable ingredient; document the ones you can't.** An ingredient with neither a
  Renovate customManager nor a written reason is a silent staleness hole — the product ships built from
  an input nobody is watching. Give each repo an `INGREDIENTS.md`: every input baked into the artifact,
  where it's pinned, its Renovate status, and what a bump does. Where no clean datasource exists (a
  rolling URL with no version, a moving `@v1` tag), say so and say what compensates — vendoring plus a
  hash pin keeps builds reproducible even when nothing is watching upstream. Don't invent a fragile
  tracker (scraping a download page for a date) just to fill a cell.

## Verifying the fetched upstream (deviation axis)

Upstream source is **fetched by tag at build time, not vendored**. How you verify it depends on what
upstream publishes — pick the strongest available and note the choice:

| Upstream publishes… | Verify by | Example |
|---|---|---|
| a checksum feed/file | fetch that checksum, verify the download against it (frozen by the pinned version) | golang → go.dev `?mode=json` SHA256 |
| signed artifacts | signature/identity (verifies a version that doesn't exist yet) | swift-toolchain → Apple installer signer |
| a git source we clone | pin the **commit digest** and verify the checkout against it | container-tools/tailscale/ed25519 → git-refs |

Record the resulting digest in `SHA256SUMS` for the record even when the gate is a signature. **Don't
invent a hand-maintained pinned hash when upstream already publishes one** — that's a divergence to avoid.

### Git sources: digest-pin, don't TOFU (and don't hand-roll the clone)

When you build from a **git clone** (not a checksummed tarball or a signed artifact), pin the **commit
digest**, not just the tag — a git tag is mutable, so a tag-only pin trusts it not to move. Use the
shared **`scripts/clone_pinned.sh REPO REF DIGEST DEST`** (bats-tested): it fetches the pinned source
into a shared cache and fails closed unless the checkout is exactly `DIGEST` (moved/forced tag, MITM,
wrong ref all bail). **Do not vendor your own `clone_pinned.sh`** — consume shipyard's.

Renovate keeps `REF` + `DIGEST` in sync with a `git-refs`/`currentDigest` customManager, so a bump
updates both and the pin auto-advances. The pin file carries both, e.g. `components/foo/version`:

```
REPO=https://github.com/acme/foo.git
REF=v1.2.3
DIGEST=<40-hex-commit-sha>
```
```json
{ "customType": "regex",
  "managerFilePatterns": ["/^components/[^/]+/version$/"],
  "matchStrings": ["REPO=(?<packageName>\\S+?)\\.git\\s+REF=(?<currentValue>\\S+)\\s+DIGEST=(?<currentDigest>[0-9a-f]{40})"],
  "datasourceTemplate": "git-refs" }
```

There is deliberately **no separately-maintained artifact hash** (`golden.sha256`) and **no manual
on-box "bless" step**: the commit digest *is* the reproducibility pin, Renovate bumps it, and a
per-bump characterization/fingerprint of the *built* output only blocks merges without a shippability
signal (see the auto-merge intent above — fix runtime regressions in `-mavericks.2`).

## Sparkle updater

- Every product ships a Sparkle updater `.app` that **must not link the product it updates** (self-update
  circularity — assert with `otool -L`). EdDSA-signed; private key is the `SPARKLE_PRIVATE_KEY` secret.
- `mavericks_add_updater_app()` self-fetches the Sparkle framework at configure time; signing/appcast use
  the shared `sign_and_appcast.sh` (fetches `ed25519-sign` via `gh` → needs `GH_TOKEN`).
- **The signing key never meets a command line or a trace.** A public repo's Actions logs are public,
  and GitHub masks only the *literal* secret: a trace, a slice or a re-encoding goes out as-is.
  `sign_and_appcast.sh` feeds the key to `ed25519-sign -f -` with `printenv SPARKLE_PRIVATE_KEY |`, so
  the shell never expands it — neither `ps` nor `sh -x` can show it — and
  `tests/sign_and_appcast_key.bats` runs it under `sh -x` and fails on any 16-character piece of the
  key. In anything of your own: never put `$SPARKLE_PRIVATE_KEY` in a command, not even
  `[ -n "$SPARKLE_PRIVATE_KEY" ]` (a trace prints it — use `printenv SPARKLE_PRIVATE_KEY | grep -q .`),
  and never decode, slice, or write it anywhere. Until 2026-09-10 the key was an argv to
  `ed25519-sign -s`, beside a comment saying it never was.
- **Every signing run proves its logs don't carry the key — before publishing.** A signing product's
  `release.yml` calls `scan-for-key.yml` between the job that signs and `publish-release.yml` (the
  snippet is at the top of that workflow): it fetches this run's finished job logs and scans them,
  plus the files about to be released, for every 12-byte window of the key's secret half as raw
  bytes, hex, and standard/url-safe base64 at each byte alignment (`scan_for_key.py`, which reports
  where, never what). A hit stops the release; the key must then be treated as public. The job runs
  under `always()` (plus the publish condition): a run that fails *after* signing left public logs
  written while the key was in use, and they are scanned too. It is a
  separate workflow because reading logs needs `actions: read` and a called workflow can't ask for
  more than its caller grants — adding it to `publish-release.yml` would break every product's
  publish. `publish-release.yml` instead looks for the scan's record on any signed release
  (`require_key_scan.sh`) and **refuses to publish** without it; `check-family-conventions.sh` fails a
  repo whose workflows sign without calling `scan-for-key.yml`, so the gap shows on a PR first.
- **A signature must satisfy the clients ALREADY INSTALLED — checked before the appcast exists.** A
  Sparkle client verifies against the `SUPublicEDKey` of the updater it has, which came from the pkg
  the feed offered last time: not the repo's `.pub`, and not the key the new pkg ships.
  `ed25519-sign`'s self-check can't see a mismatch (it checks against the public half of the key it
  was handed), so `sign_and_appcast.sh` runs `assert_update_trusted.sh` after signing: it reads the
  new pkg's `SUFeedURL`, fetches that live feed's enclosure pkg, and `ed25519-verify`s the new
  signature against *that* pkg's updater key (`updater_pubkey.sh` reads a pkg's key and feed). No
  appcast is emitted on a refusal. A first release (feed 404) is checked against the new pkg's own
  key; a feed that can't be *read* fails closed rather than pretend to be a first release.
  - **Changing a product's key** (e.g. moving to the org-wide key): ship the new `.pub` in a **bridge
    release signed with the OLD key** — the check passes and says the next release needs the new
    key — then switch `SPARKLE_PRIVATE_KEY` after it publishes. Swapping key and secret together
    fails the check, because every installed updater would reject that release. Only a deliberate
    decision to strand installed clients passes `--allow-key-change`, and the workflow must say why.
- **A menu/systray "Check for Updates" MUST launch the updater via LaunchServices, not fork+exec.** Run
  `/usr/bin/open "<…>/ProductUpdater.app" --args --user`, NOT `NSTask`/`exec.Command` on the executable
  inside `Contents/MacOS`. Sparkle's package install runs its privileged helper via
  `AuthorizationExecuteWithPrivileges`, which needs a LaunchServices session; a fork+exec'd host has none,
  so the install dies with `SUSparkleErrorDomain 4005` / `errAuthorizationInternal (-60008)` (or hangs).
  The updater's `Info.plist` (a normal app, not `LSUIElement`) exists to satisfy this — the caller must too.
  `--user` = interactive check; the daily LaunchAgent uses `--background` and is unaffected (it never
  runs a privileged install).
- **The Sparkle comparison version must be dotted-numeric AND monotonic — the shared derivation makes
  it so; never hand-roll it per product.** `SUStandardVersionComparator` only totally orders `X.Y.Z.N`,
  and it reads the `-mavericks.N` suffix (or any stray letter) as EQUAL — so a same-upstream repackage
  would be invisible to auto-update ("you're up to date"). The human string (`9.9p2-mavericks.3`) stays
  in `<sparkle:shortVersionString>` / `CFBundleShortVersionString`; the *compared* value
  (`<sparkle:version>` / `CFBundleVersion`) is derived to a numeric-only form by **both**
  `scripts/gen_appcast.sh` and `MavericksSparkle.cmake`, which MUST stay identical (a mismatch means the
  updater silently believes it's current). The derivation, in order:
  - `-mavericks.N` → `.N` (the packaging axis);
  - a **monotonic** in-version patch letter → `.` — the only one in the family is OpenSSH-portable
    `X.YpZ` → `X.Y.Z` (`p2` is *newer* than `p1`, so `9.9p2` → `9.9.2` is order-preserving, and
    `9.9p2 < 9.10p1` stays `9.9.2 < 9.10.1`);
  - the result must be purely dotted-numeric, or the appcast step **fails closed**.
  Most upstreams need no special case: semver (`1.26.5`), bare date (`20260727`), and self-upstream
  dates/semver are all already dotted-numeric — variable length is fine (a date is one component, semver
  three). Only a **letter** needs a rule, and openssh's `pN` is the family's first.
  - **Adding a new non-numeric upstream shape:** put the transform in the shared derivation (both files,
    identically) — never in a product's build, or the appcast and the updater's `CFBundleVersion` drift.
    Fold in a separator ONLY if it is monotonic (a higher suffix = *newer*, like `pN`). A **non-monotonic**
    prerelease suffix (`-rc1`, `beta` — the suffix means *older* than the release) must NOT be dot-joined
    (`1.2.3rc1` → `1.2.3.1` would sort ABOVE `1.2.3`); leave the fail-closed check to force an explicit
    decision (e.g. map the prerelease into a lower band like `1.2.2.9001`). The fail-closed gate is the
    point — it catches exactly the "compares EQUAL / compares backwards" bugs before they ship.

## App icons (forced decision — no unopted placeholders)

Every shipped app — **including the Sparkle updater** — must make an EXPLICIT icon decision.
`mavericks_require_icon(TARGET t ICNS <path>)` and `mavericks_add_updater_app(… ICON <path>)` both
FATAL at configure time if the icon is missing OR is a **registered placeholder** — its sha256 is
listed in shipyard's `scripts/placeholder-icons.sha256`. The one way to ship a generic/
placeholder icon is the explicit opt-in `-DMAVERICKS_ALLOW_GENERIC_ICON=ON` (or `ALLOW_GENERIC`).

This gate exists because an agent-generated solid-colour stand-in once shipped in a product as if it
were real artwork, waved off as a "minor" follow-up. **If you generate a placeholder icon, register
its sha256 in `placeholder-icons.sha256`** in the same change — then the product cannot build a
release until real artwork (a different hash) replaces it, or someone opts in on purpose. Both icon
entry points call the shared `mavericks_reject_placeholder_icon`, so neither the main-app nor the
updater path can smuggle one through.

## Artifact conformance (checked at package time)

The conventions gate constrains the REPO. `check-artifact-conformance.sh` constrains what comes OUT,
and runs at package time — before publish, where the artifacts exist and `pkgutil` does.

It exists because every piece was already checked in isolation — the compat guard reads binaries,
`set_install_floor` stamps a floor, `sign_and_appcast` signs, `publish-release` checksums — and
**nothing asserted they agree with each other**. A release whose `.pkg`, appcast, checksums and tag
disagree is incoherent however it was built.

| Axis | Checked |
|---|---|
| Itself | `.pkg` / appcast / tag versions match; the enclosure names a published asset at its real length, and points into THIS release |
| Neighbours | every `.pkg` of one release agrees on the version; where `lines/` exists, each identifier carries its line; **variants agree about their ingredients** |
| Siblings | version scheme `<upstream>-mavericks.N`; identifier `dev.modernmavericks.*`; a product archive declares the 10.9.5 floor |

**This constrains outputs, not methods.** Products here build in genuinely different ways — a Go
toolchain, a boot2docker iso, libswiftCore, an openssh — and making those look alike would buy
uniformity by inventing a bespoke "kind" per product. If a check can only pass by changing *how* a
product is built rather than *what it emits*, it is the wrong check.

**Structure matters more than it looks.** A product archive (`Distribution`) declares an install
floor; a component package (`PackageInfo`) cannot — floors are a `productbuild` concept — so its
minimum lives in the appcast instead. golang's cross product is exactly that: it TARGETS 10.9 but RUNS
on 11.0+, so demanding 10.9.5 of it would be wrong.

**Record what a variant was built FROM.** `sh "$SHIPYARD_SCRIPTS/build-info.sh" dist/build-info-<variant>.txt
key=value …` at package time, and ship it as a release asset. Conformance compares any key appearing in
more than one variant, except those that are *supposed* to differ (`variant`, `arch`, `prefix`, `pkg`,
`identifier`).

This exists because **artifacts cannot answer the question**: golang's native `.pkg` carries the CA
bundle and the legacy-support shim, its cross `.pkg` legitimately does not (cross-built apps look at
the native prefix). "Both variants used the same shim" is a claim about *inputs*, which no payload
inspection can settle — so the build writes it down rather than a checker guessing later. It also means
a user can read what a release was made from.

**Deviations are declared in `INGREDIENTS.md`, with a reason, scoped to a filename glob:**

```markdown
## Conformance deviations

- version:upstream-swift-*.pkg: mirrored verbatim from swift.org, so the version is upstream's own
```

Scoping is the point: swift-toolchain republishing swift.org's `.pkg` must not license the
build-support tarball it *does* build to drift. An unscoped deviation quietly covers artifacts nobody
meant to excuse.

## A "transitional" decision without an exit task is a permanent one

When a review accepts something as transitional — "for now", "until X is
factored out", "a defensible first step" — **that acceptance must create a
task, with the exit condition written down.** Otherwise the transitional state
becomes the permanent state, silently, and the reasoning that justified it is
buried in a review nobody re-reads.

The case that produced this rule: macho-tools' `macho9` CLI was specified as
"one library, one multi-call CLI". Its plan told the implementer each verb
should be "delegating to existing code" — wording that permits calling a
library function OR running an existing binary. The implementer chose to
`fork`/`exec` the sibling `change_dylib` binary for four verbs, because the
ordinal-renumbering logic was not yet factored out and that file was outside
the task's scope. The controller caught it and made it the review's central
question. The reviewer approved it, with genuinely good reasons: no shell so no
injection surface, refusal fidelity preserved through `WEXITSTATUS`, and it
avoided re-implementing renumbering that had twice shipped loader-crashing
bugs.

Every step of that was correct. The result was still wrong: two plans later,
`macho9` was still a delegator, and a follow-up plan to replace those tools
with wrappers onto `macho9` turned out to describe a **cycle** — the wrapper
would call `macho9`, which would call the binary the wrapper replaced. Nobody
had written down when the transition ends, so it did not.

- **Name the exit condition when you accept the compromise**, not later:
  "delegate by subprocess until `ordinals` is extracted; then convert" is a
  task. "Defensible for now" is not.
- **Put it in the plan, not only in the review.** Reviews are read once;
  plans are executed.
- **A later plan that assumes the transitional thing is finished is the
  failure mode.** The follow-up plan here was written against what the CLI was
  *specified* to be rather than what it *was* — and only a whole-branch review
  reading the actual code caught it.
- Corollary for spec wording: prefer "call the library function" over
  "delegate to existing code". Ambiguity in a plan is executed, not queried.

## Family conventions (checked, not just written down)

`sh "$SHIPYARD_SCRIPTS/check-family-conventions.sh"` runs in every product repo's CI and **fails the build**
on any of these. It exists because seven repos started from one shape and drifted into two publishers,
four concurrency policies, three repos not running their own tests, and 11 copies of one incantation —
none of which anything detected. A convention that is not checked is a convention that drifts.

| Check | Why it is a gate |
|---|---|
| `release.yml` declares `concurrency:`, its group IS keyed on `github.run_id`, and `cancel-in-progress` names `pull_request` | A run that can publish must be alone in its group. `cancel-in-progress: false` protects the RUNNING job and not the QUEUED one, so a shared group silently discards releases — golang lost one 13 seconds after the run that evicted it. Both halves are checked, because either alone lets the old shape back in |
| Test files exist ⇒ some workflow runs them | Nine unrun tests, two silently rotted, is what "we'll wire it up later" looks like |
| `INGREDIENTS.md` exists | An input nobody documented is an input nobody is watching |
| No Renovate key the shared preset already sets | A local copy silently stops tracking the preset when the preset changes |
| The release publishes a notes body | An empty Release body ships unnoticed — tailscale's did, on every release |
| `VERSION` is **not committed** (an untracked one is fine — it's a build product) | The committed copy drifts: container-tools built `-mavericks.14` from a file saying `.2`, which also made its tag path (`tag == VERSION`) impossible to satisfy |
| Every workflow parses **with duplicate keys rejected** | A second `with:` on one step is legal YAML — last key wins — so ordinary parsers accept it and GitHub refuses to run the workflow. No other gate can catch it, because CI never starts |
| No `INGREDIENTS.md` row marked ❌ unless it says **untrackable** | An ingredient nobody tracks goes stale silently; a bare ❌ reads as an oversight rather than a decision |
| A **committed** `build/` or `scripts/upstream-release-notes-url.sh`, or an `INGREDIENTS.md` line `No upstream release notes: <reason>` | A `-mavericks.1` exists to ship someone else's changes; notes that name the version without linking what changed leave the reader to go find it |
| A workflow that runs `sign_and_appcast.sh` has some workflow calling `scan-for-key.yml` | A signing run's logs are public and GitHub masks only the literal secret; `publish-release.yml` refuses a signed release with no scan record, and this catches the missing job on a PR instead |
| If `lines/` exists, every `lines/<id>/UPSTREAM_VERSION` has its OWN **capped** Renovate manager | An uncapped line walks onto the next major it was never built for; an unmanaged line goes stale silently; one manager spanning lines cannot cap each |
| A Renovate manager whose captured pin ends in `-mavericks.N` has a `regex:` versioning that captures N | Default versioning coerces `-mavericks.N` away, so every repackage compares equal and the pin never moves — silently, with the dep listed as tracked. swift-runtime missed three swift-toolchain releases this way |

Wire it with the reusable workflow — three lines, and it never changes when a check is added:

```yaml
jobs:
  conventions:
    uses: ModernMavericks/shipyard/.github/workflows/family-conventions.yml@v1
```

It checks out shipyard itself rather than expecting `$SHIPYARD_SCRIPTS`, so it also gates repos that do
not consume shipyard's CMake side at all (swift-toolchain builds and mirrors — no install step, no
updater, no `.pkg`). A gate only some repos can run is not a family convention.

Adding a check is cheap; adding one **without its rule here** is a trap for the next person. Land both
in the same commit.

## Running a repo's tests

- **Use the shared runner: `sh "$SHIPYARD_SCRIPTS/run-repo-tests.sh" [ctest-preset]`.** It runs every
  top-level `tests/*.sh` and `tests/*.bats` — or `ctest` where that is the driver — so a newly added
  test file runs the day it lands. Subdirectories are fixtures and sub-suites with their own entry
  points, not tests to run.
- **A test that cannot run yet exits 77 to SKIP**, the same idiom as ctest's `SKIP_RETURN_CODE 77`.
  Guard on the artifact you need (`[ -d "$OUT" ] || { echo "not built — skipping"; exit 77; }`) rather
  than failing a CI run that was never going to have it.
- **`bats` is required, not optional.** `install@v1` installs it on any runner that lacks it, so a
  `.bats` file with no bats means a broken environment — `run-repo-tests.sh` reports **FAIL**, not
  SKIP. A skipped assertion is one nobody is checking, which is the hole that let two tests rot.
  Working locally without bats: `brew install bats-core` (or your platform's package).
- **An assertion must be able to fail — on 10.9 too.** On bash < 4.1 (10.9's `/bin/bash`, which
  pkgsrc's bats runs under) a failing `[[ ]]` that is not a test's last command does not fail the
  test, and on any bash a bare `! cmd` never trips errexit: both read as checks and check nothing.
  End them `|| false` (or use `run ! cmd`). `check-shell-portability.sh` bans the bare forms; it found
  seventeen in shipyard and fourteen in ed25519, all green on 10.9 whatever the code did.
- **Never hand-enumerate test files in CI.** That is how `macports-legacy-support` ended up with nine
  test files it had not run since each was written — two of which had rotted: one asserting Renovate's
  pre-migration `fileMatch` key, one checking an `.icns` filename that changed when the repo was
  renamed. Neither was a product bug; both were invisible because nothing ran them.

## New-project checklist

1. `renovate.json`: extend shipyard; add the upstream `customManager` + patch/minor rules; ensure a
   PR check exists (or set `ignoreTests: true` if no build). For *prompt* automerge, enable **Allow
   auto-merge** AND add **branch protection requiring the build check** — both are needed (see the
   Renovate section for the exact commands and the typo-blocks-all-merges caveat).
2. `UPSTREAM_VERSION` (bare); `/VERSION` in `.gitignore`.
3. `build/lib.sh` (`upstream_version()`), `build/version.sh`, `build/release-notes-file.sh` — copy from
   legacysupport/golang.
4. `release.yml`: pick a release model; three triggers; `ver` step with the non-main guard; `gh release
   create`; `cancel-in-progress: false` if auto-cutting.
5. `release-notes/README.md`; `build/upstream-release-notes-url.sh` (a port: where upstream's notes
   for a version live — see Release notes); Sparkle updater target; `SPARKLE_PRIVATE_KEY` secret.
6. Choose the upstream-verification method; note it if it deviates from a sibling.
7. If the repo bakes in build ingredients (anything it's built WITH, not the upstream it ports): make
   each pin a **file**, give each a Renovate customManager, add the `repackage-on-ingredient-bump`
   caller, and record the lot in `INGREDIENTS.md` — including any ingredient you deliberately left
   untracked and why. No file-based ingredient pins → no caller (say that in `INGREDIENTS.md` too).
   Wire `ingredient-notes.sh` into the notes step and `check-ingredient-pins.sh` into CI so releases
   state which ingredient moved.
9. Call `check-family-conventions.sh` in CI, and run the suite with `run-repo-tests.sh`. The gate fails
   on: no `concurrency:`; test files nothing runs; no `INGREDIENTS.md`; a Renovate key the preset
   already sets; a release that publishes no notes body.
8. Check in `.claude/settings.json` pointing at the `modernmavericks` marketplace (hosted in
   `mavericks-shipyard`) so contributors' agents load these conventions — do NOT copy the SKILL.md:
   ```json
   {"extraKnownMarketplaces": {"modernmavericks": {"source": {"source": "github", "repo": "ModernMavericks/shipyard"}}},
    "enabledPlugins": {"modernmavericks@modernmavericks": true}}
   ```
   **That file alone loads nothing.** It registers the marketplace and enables the plugin, but since
   Claude Code 2.1.195 a project setting does not *install* a plugin from an external source — so a
   fresh clone, a new repo and a new contributor all get no conventions, silently. Each contributor
   installs once, at **user** scope, which then covers every family repo:
   ```sh
   claude plugin install modernmavericks@modernmavericks --scope user
   ```
   and turns on auto-update for the marketplace (`/plugin` → Marketplaces → modernmavericks → Enable
   auto-update; it is off by default for third-party marketplaces). Do NOT install at project scope:
   it covers only that one path, it pins whatever version was current, and `plugin uninstall --scope
   project` later rewrites this tracked settings file (it drops the `enabledPlugins` entry).
   `plugin.json` deliberately has no `version`, so every push to shipyard's `main` is an update —
   with one pinned, contributors got an update only when someone remembered to bump it (three bumps
   against ten-plus skill edits left installs 200 lines behind).

   **When a human has to act, in general.** A marketplace's catalog refreshes only three ways: the
   background auto-update task (shortly after session start), an explicit `claude plugin marketplace
   update <name>` / `/plugin`, or installing `plugin@marketplace`, which forces one. Auto-update is ON
   for Anthropic's own marketplace and OFF for every third-party and local one — ours is third-party,
   which is why the toggle is a step at all. It cannot be set from a repo: the per-marketplace
   `autoUpdate` field is honoured only in MANAGED (enterprise) settings. So someone must act when:
   - a contributor is new to the marketplace (install once, enable auto-update once);
   - the plugin declares a `version` (nothing ships until it is bumped — hence ours has none);
   - a change is needed in the CURRENT session (refresh, then `/reload-plugins` or restart; `-p`
     sessions can reload only on 2.1.260+);
   - refresh is suppressed — `DISABLE_AUTOUPDATER`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, a
     seeded plugin dir, managed settings blocking the marketplace, or being offline.
   Docs: code.claude.com/docs/en/discover-plugins, /plugins-reference, /plugin-marketplaces.

## Consolidation backlog

The family is mid-consolidation: each item below replaces per-repo machinery with one shared
implementation. Detail lives in `docs/superpowers/specs/2026-07-30-family-consolidation-umbrella.md`
in shipyard (that dir is gitignored, so this list is the durable half). **When you land one, strike
it here.** A silently dropped increment is how the family drifted in the first place.

- [x] Shared scripts dir (`$SHIPYARD_SCRIPTS`), shared test runner, conventions gate — done 2026-07-30
- [x] Reusable `publish-release.yml` — done 2026-07-30; all seven repos publish through it
- [x] Promote `version.sh` / `lib.sh` / `release-notes-file.sh` into shipyard — done 2026-07-30
- [x] One publisher — done 2026-07-30 with increment 2. The two version *models*
      (derive-from-tags vs committed `VERSION`) remain, and are a real design question, not drift
- [x] Automerge policy stated in the preset — done 2026-07-30. **Ship-if-green**: patch, minor and
      major automerge once the build passes; fix forward in a `-mavericks.N+1` release. Exceptions
      only where a bad bump would build fine and be wrong, and the gate demands the reason
- [x] **Remove `ed25519-sign -s`** (the key as an argv) — done 2026-09-11 (mavericks-ed25519
      3efe029), once `sign_and_appcast.sh` passed the key with `-f -` on `main` (7369bd2) and
      ed25519 20221003-mavericks.4 had shipped `-f`; shipyard v1.0.151 signed through that path.
      The *release* dropping `-s` is the next ed25519 release after 3efe029
- [x] **Every signing product calls `scan-for-key.yml`** — done 2026-09-11: openssh, tailscale,
      legacysupport, swift-runtime, porthole, golang, container-tools, clang, magic-trackpad2 and
      shipyard. `require_key_scan.sh` now refuses a signed release with no scan record, and
      `check-family-conventions.sh` (check 12) fails a repo that signs without the job. compat is
      exempt by omission: it is not on GitHub
- [x] One release-notes generator for the family (`release-notes.sh`), one shape, gaps fatal rather
      than silent — done 2026-09-11. Per-repo migration (13 repos, swift-runtime first) and the three
      enforcement layers (conventions-gate check, publisher body-shape validation, artifact-conformance
      appcast-vs-body agreement) follow as separate plans
- [ ] **North star, not yet designed:** should a product repo carry build machinery at all? One
      declarative config per repo (upstream, verification, binaries, ingredients, updater) that
      shipyard turns into the build, package, release, and checks — a repo that cannot express a
      difference cannot drift into one. The hard part is where genuine difference lives
      (container-tools has no single upstream; swift-toolchain ships no end-user `.pkg`)

## Common mistakes

- Hardcoding the upstream version in a test → self-blocks the next Renovate automerge.
- `ignoreTests: false` (default) but no PR check → automerge **stalls forever**. Add the `pull_request`
  gate or set `ignoreTests: true`.
- Auto-cutting on main with `cancel-in-progress: true` → a rapid second push cancels the release mid-flight.
- Copying an older repo's **shared-group** `concurrency:` block → a queued publishing run is evicted by
  the next arrival and its release silently never happens: no tag, nothing red. Key the group on
  `github.run_id` so a run that can publish is alone in it.
- Adding a PR trigger without the `rel=no unless main` guard → a PR build tries to publish.
- Committing `VERSION`, or building assuming it exists → it's gitignored/workflow-written.
- Reaching for a PAT to create the release tag → `gh release create` mints it under `GITHUB_TOKEN`.
- Pushing a workflow change to a product while one of its release runs is in flight → that run's
  publish fails `403 Resource not accessible by integration` creating the release. `GITHUB_TOKEN`
  may not create a tag on a commit whose `.github/workflows/` differ from the default branch's, and
  your push just made them differ. Nothing is published and no tag is left; re-dispatch from the new
  `main`. (openssh 9.9p2-mavericks.4, 2026-09-11: re-running the failed job fails the same way.)
- Vendoring shipyard or pinning its action to a SHA → consume `@v1` via the install action.
