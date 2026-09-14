# Backlog

Family-wide work that is worth doing and is not worth interrupting something else to do. Drop an
item here instead of spawning an agent at shipyard mid-flight; several sessions touch this repo at
once, and a queued note costs nothing while a concurrent branch costs a rebase.

Each entry carries the **evidence**, not just the conclusion — including what was already tried and
did not work, so the next person does not re-walk it. Delete an entry when it lands.

---

## 1. Conventions check: a test that hardcodes the upstream version blocks its own bumps

Two repos now carry one, so it is a pattern:

- **openssh** `tests/derive-upstream-version.bats` asserted the derived value equals `"9.9p2"`.
  Moving the pin to `V_10_5_P1` failed it, and `run-repo-tests` gates the build, so the release never
  ran. Fixed 2026-09-13 in `bba3750`.
- **clang** `tests/version-test.sh` hardcodes the upstream version and blocks its Renovate automerge.
  Not fixed (another session owns that repo).

A test that must be edited to accept a new upstream is not testing the upstream, it is blocking it.

**The distinction to encode:** hardcoding is fine when the test pins a **transform** with fixed
inputs (`V_9_9_P2` → `9.9p2` is true forever). It is wrong when the test pins **plumbing** — that the
build reads the committed pin and acts on it — because that holds at every version and the literal
only encodes today's. openssh's fix shows the shape: transform cases keep fixed inputs, the plumbing
case derives its expectation from the committed tag.

**Proposed check:** flag a tracked test file containing a string literal equal to the repo's current
upstream pin (`components/*/version`, `UPSTREAM_VERSION`, or the `renovate:`-annotated line in
`build/versions.sh`). False-positive risk: a fixture legitimately using the current version as sample
input — needs the usual reasoned escape hatch.

## 2. compat guard: replace the post-10.9 denylist with an SDK-derived allowlist

`scripts/assert_binary_compatible.sh` decides post-10.9 imports with one denylist:

    POST_10_9='_clock_gettime|_clock_gettime_nsec_np|_os_unfair_lock_.*|_os_log.*'

A denylist must predict which future API someone will accidentally call. Two independent proofs it
does not:

1. **swift-runtime already patched around it** — `scripts/guard.sh` there exports a widened
   `MAVERICKS_POST_10_9_SYMBOLS`, commenting that the shared default "only covers os_unfair_lock +
   os_log single-underscore".
2. **openssh, 2026-09-13** — a patch called `launch_activate_socket()` (10.10-era, undeclared in the
   10.9 SDK). It compiled, linked, and the guard said `1 binaries clean ... no post-10.9 imports`.

The 10.9 SDK is **frozen**, so an allowlist derived from it is complete by construction, and
`fetch_sdk.sh` already pins the SDK by hash so the two cannot drift.

**Already tried and rejected — do not repeat:** a naive union of *every* exported symbol in the SDK.
703 dylibs/stubs yield 214,822 symbols (7.2 MB; 1.4 MB gzipped) and it wrongly approves
`_clock_gettime` (exported by `CoreWiFi.framework`, which bundles its own — nothing links CoreWiFi)
and `_launch_activate_socket` (exported by `usr/lib/system/libxpc.dylib`). Scope the allowlist to
**the libraries a product actually links** — its link line, or `otool -L` of the built binary —
taking each library's exports from the pinned SDK. That mirrors how the linker resolves.

**Honest limits.** It would *not* have caught the openssh case: libxpc genuinely exports that symbol
in the SDK and on a running 10.9.5 box (the call links and returns `ENOTSUP`). That defect was
source-level — undeclared, so the compiler guessed an SPI's prototype — which is item 3's job. It
catches "does not exist", not "exists but is unavailable here". **Weak imports must survive:**
swift-runtime permits some post-10.9 families *only* when imported weak, and deliberately refuses
`os_unfair_lock` because its runtime calls it unguarded.

**Language coverage is free** — the guard reads Mach-O via `nm` and does not care what produced the
binary, so unlike item 3 this protects every product, not just the C ones.

## 3. Adopt `-Werror=implicit-function-declaration` as a family default, with an opt-out

Apple's old clang treats an undeclared function as a *warning*, so the openssh case compiled, linked,
passed the guard, and buried the only real signal in a 5,800-line log. An undeclared function is also
worse than it looks: the compiler invents a prototype, and here that was an SPI.

**Nothing breaks today** — zero `implicit declaration` hits across all 12 reachable products' most
recent successful `release` runs on main (2026-09-13 survey).

**But the shared CMake line is the wrong lever.** `Mavericks.cmake:29`'s `add_compile_options` is the
one shared site, yet for 5 of 6 consumers it governs a *single generated ObjC file compiled against
the modern SDK* — nearly inert. The heavy C, the 10.9 SDK, and the motivating bug live in per-repo
shell scripts, and shipyard has **no shared CFLAGS**. Seven sites, six repos:
`openssh/build/build-openssh.sh:27`, `openssh/build/build-libressl.sh:58`,
`macports-legacy-support/build/build-lib.sh:19`, `ed25519/build/build-tools.sh:29,31`,
`porthole/build/fetch-s6.sh:15`, golang's `build-{cross,native}.sh` clang wrappers,
`swift-toolchain/build-llvm.sh:35`. Suggested vehicle: `MAVERICKS_STRICT_CFLAGS` in `scripts/lib.sh`.

**Scope: 5 products, not 13.** openssh (~300 TUs), magic-trackpad2, macports-legacy-support (44
files), porthole, ed25519 compile meaningful C/ObjC. Four others compile 1-6 ObjC updater TUs;
swift-toolchain's C is vendored LLVM; 1password and signal-desktop compile none.

**Opt-out:** mirror `MAVERICKS_REQUIRE_APPLECLANG` for the switch, plus a glob-scoped
`- implicit-decls[:<glob>]: <reason>` in `INGREDIENTS.md` — `deviations.sh` already exits 1 on a
reasonless entry and `check-family-conventions.sh` already has the `deviated <check> <path>` helper.

**Gating precondition — do not skip.** Injecting this into `CFLAGS` *before autoconf* can silently
flip feature detection: a probe that fails reads as "feature absent". Rerun openssh's and libressl's
`./configure` with and without the flag and diff `config.log` first.

**Two dead ends, recorded.** `/usr/bin/clang` on the 10.9 box (Apple LLVM 6.0) rejects
`-Wunguarded-availability`, `-Wunguarded-availability-new` and `-Wpartial-availability` as unknown,
and the 10.9 SDK carries no availability annotations — so that flag is only worth adding,
`check_c_compiler_flag`-guarded, on the modern-SDK CMake surface (and its `-new` variant defaults to
a 10.13 threshold, leaving 10.10-10.12 uncovered). Unsettled: whether the macos-26 AppleClang 21
runner already errors on this by default; one probe job settles it.

## 4. Convention: fix Renovate blockers on the PR's branch, not by bypassing to main

When a Renovate PR is blocked by something in the source tree, push the fixing commits to
`renovate/<whatever>` so the PR goes green and automerges. Do not fix on main and leave the PR
superfluous.

The model here is ship-if-green automerge: Renovate proposes, the build gates, the bot merges. Fixing
on main puts an agent on the one path with no PR-time gate, closes the PR as "already up to date" so
the bump was never Renovate-driven, and risks breaking main when fix and bump are only correct
together.

**The case (openssh, 2026-09-13).** Renovate #4 proposed OpenSSH v10, blocked because three vendored
Apple patches no longer applied. Patch rewrites and version bump are *only valid together* — the new
patches do not apply to 9.9p2. The agent reasoned "therefore one atomic commit to main" and pushed.
The atomicity constraint was real; the inference was not. **Pushing the patch commits onto the
Renovate branch satisfies both.** Refreshing a stale branch needs no push either: every Renovate PR
body carries a `- [ ] <!-- rebase-check -->` checkbox.

**Exception:** a blocker genuinely independent of the bump — wrong at the old version too — is fixed
on main and Renovate rebases. Test: does the fix make sense *without* the bump?

Belongs in the conventions skill, near the Renovate & automerge section. Documentation, not a gate.

## 5. Convention: show the diff before shipping agent-authored code

Before an irreversible step that ships code the agent **authored** — written or substantively
re-derived, as opposed to moved unchanged or already reviewed — put the actual diff in front of the
human, not a description of it. Weighted heavily when the code is security-sensitive (openssh,
ed25519, the signing path), when the push auto-releases to users via Sparkle, and when the agent made
judgment calls a summary cannot convey.

**Why prose is not a substitute:** "ported the patches, verified natively" is equally consistent with
a correct port and a subtly wrong one. Authorization granted on that basis is not informed
authorization, and closing that gap is the agent's job, not the human's.

**The case (openssh, 2026-09-13).** Three vendored patches re-derived for 10.5p1, built and tested
natively, then pushed to main on an instruction given without the human having seen any code; two
releases went out. The work demonstrably needed review — the agent found three of its own errors
mid-flight: an `add_file()` call passing 8 arguments to a 9-parameter function, a wrong launchd API
choice, and a false claim about libSystem already committed to a repo.

**What a good review artifact looks like here:** not the vendored `.patch` files, whose diffs are
diffs-of-diffs and unreadable — the **effective change to the upstream source** (patched tree vs
pristine tarball), plus an explicit split between what carried over unchanged from the previous
patch set and what the agent authored this time. In the openssh case that reduced "we ported OpenSSH
to 10.x" to six reviewable items, four of them one-liners.

Suggested default: openssh, ed25519, and anything touching signing or key handling get a diff-first
pause regardless of how routine the change looks.

## 6. Comments gate: two blind spots in `check-comments.sh`

**Cannot see inside heredocs.** ~40 lines of prose in `package-pkg.sh`'s rendered pre/postinstall —
including the whole R-P1-24 two-updaters-forever reasoning — will never be swept or re-checked. Known
limitation in the comments spec; demonstrated during the shipyard-cmake collapse, 2026-09-13.

**Ignores trailing comments entirely.** `ci.yml`'s untagged `# the CMake modules gate on Apple clang`
passes only because it shares a line with code. This is ruling 3's deliberate scope exclusion, now with
a live example.

## 7. No consumer repo documents how to obtain shipyard outside CI

All 14 surveyed 2026-09-13; the real instructions live in code comments, CLAUDE.md, or test scripts. The
shipyard-cmake cutover makes this worse — a developer now needs shipyard-cmake installed — and only
macho-tools' README was fixed, because there the existing text became actively false rather than merely
absent.

## 8. 1password's `cmake-10_9-gate` job cannot succeed as checked out

It runs `cmake --preset cross` against a "Porthole viewer", but the repo has no CMakeLists.txt, no
CMakePresets.json and no Porthole source. Pre-existing and unrelated to the flag day, which deliberately
left it alone (flag-day spec D8).

## 9. Check 18 has three blind spots, and real breakage hid in all of them

It reads workflow `run:` blocks plus `git ls-files -- '*.sh'` minus `tests/`, so `*.bats`, `tests/*.sh`,
extensionless executables, `*.cmake` and `CMakeLists.txt` are invisible; and it ignores a bare `(` even
inside files it does read.

**Concrete evidence, all found during the 2026-09-13 cutover:** porthole's
`tests/test_standalone_build.bats` ran a real configure that CI executes via `run-repo-tests.sh`;
porthole's extensionless `bin/generate-viewer` printed the build recipe users follow; and five
`echo "... (build it: cmake --build ...)"` recipes across clang, golang, openssh and swift-runtime.

Across the fourteen repos the gate saw a **minority** of the real call sites — magic-trackpad2 was 4
visible against 18 invisible, macho-tools 2 of 12, macports-legacy-support 2 of 10.

A gate that reports `ok` because it did not look is worse than no gate, because the `ok` is believed.

## 10. Check 16 has two blind spots of its own

It matches only `.cmake/package[s]`, so a locator reading `$HOME/.local/share/cmake/...` is invisible —
clang and golang each carried a second locator in `build/versions.sh`, and swift-runtime two more in
`package.sh` and `scripts/guard.sh`.

It also skips `tests/` entirely, so a locator there can match its pattern exactly and still never be
reported — magic-trackpad2's `tests/test_appcast_notes.sh` read `~/.cmake/packages/MavericksShipyard`
and the gate said nothing.
