# Build ingredients

Everything baked into what shipyard ships, and how a change to it reaches a release. shipyard compiles
nothing: it ships CMake modules, shell scripts, and the Sparkle updater template every product renders.
Its "build inputs" are therefore the things those scripts fetch on a consumer's behalf.

This repo is consumed through a **moving** tag. Fifteen repos pin `@v1`, so anything merged here reaches
all of them within minutes — which is why the version is derived from the commit count (see
`scripts/shipyard-version.sh`) rather than bumped by hand.

| Ingredient | Pinned in | Renovate | On a bump |
|---|---|---|---|
| Sparkle 1.27.3 (updater framework) | `MavericksSparkle.cmake` (`mavericks_fetch_sparkle`) | ❌ **untrackable** by a standard manager: the version is a literal inside a CMake function, not a dependency declaration. Deliberate — Sparkle 1.x is the last line supporting 10.9, so a bump is a decision, not a routine update. | hand-edit, then the next push cuts a version like any other change |
| MacOSX10.9 SDK | `scripts/fetch_sdk.sh` (`MAVERICKS_SDK_URL` + `MAVERICKS_SDK_SHA256`, phracker/MacOSX-SDKs 11.3) | ❌ **untrackable**: pinned by SHA-256 against a frozen third-party release. There is no newer 10.9 SDK to move to; the pin exists to prove the bytes, not to track a stream. | n/a — a change here would mean a different SDK, which is a deliberate port decision |
| GitHub Actions (`actions/checkout@v7`, `actions/download-artifact@v8`, `actions/setup-python@v7`, `actions/upload-artifact@v7`, `softprops/action-gh-release@v3`) | `.github/workflows/*.yml` | ✅ native `github-actions` manager | automerges on green (`ship-if-green`), and the merge itself cuts the next shipyard version |
| `bats` (shell test driver) | installed by `.github/actions/install` from the platform package manager | ✅ tracked by the package manager, not pinned here | a new bats reaches CI on its next run; the suites are version-agnostic |
| cmake (any, ≥ 3.16) | not pinned — whatever is on `PATH` | ✅ tracked by whatever installed it, not by us | nothing: shipyard deliberately has no opinion about which cmake you use. `find_package` discovery goes through the CMake user package registry, so it does not depend on that cmake's `CMAKE_SYSTEM_PREFIX_PATH`. Install shipyard's pkg before cmake and the scripts half still works; run `register-with-cmake.sh` afterwards to finish |
| shipyard's own version | `UPSTREAM_VERSION` (the **line**) + `git rev-list --count` | n/a — first-party | every push to `main` cuts `<line>.<count>`; `@v1` moves to it |

No upstream release notes: shipyard is its own upstream -- it ports nothing, so there are no
someone-else's notes for a release to link.

## Release-doctrine surface

Four more scripts (`scripts/declared-state.sh`, `scripts/release-state.sh`,
`scripts/release-needed.sh`, `scripts/release-state-record.sh`) and one more reusable workflow
(`.github/workflows/reconcile.yml`) ship as of this release. Consumers reach all five the same way
they reach everything else here: through the moving `@v1` tag. What they do and how a product wires
them in is documented in the conventions skill ("A release is a declared state, not an event") and
the design spec, `docs/superpowers/specs/2026-09-12-release-doctrine-design.md`.

shipyard itself carries no `## Declared state` section. Its version is
`<UPSTREAM_VERSION>.<commit count>` (see the last row of the table above), so its own state changes
on every push, and every push already publishes by design. Adopting the digest path here would only
describe that status quo more slowly -- it is shipyard's declared exception, not a pattern to copy.

## Conformance deviations

`check-artifact-conformance.sh` holds each release's artifacts to the family's schemes. Two of them
assume a version of the form `<upstream>-mavericks.N` that is also the tag. shipyard's is neither, on
purpose. Machine-read by `artifact-facts.sh` as `- <check>[:<glob>]: <reason>` (the reason is the rest
of that one line):

- scheme: shipyard ports nothing, so there is no upstream to suffix -- its version is <line>.<commit count> (scripts/shipyard-version.sh), cut on every push to main.
  Every artifact still carries that one version: the pkg, the appcast and the tag agree, and conformance
  checks that they do.
- enclosure-url:appcast.xml: the release tag is v<version> (fifteen repos pin @v1 or @vX.Y.Z, so the v is load-bearing) while the pkg and appcast carry the bare version, so the feed's /download/v<version>/ URL reads to this check as another release.
  The check assumes tag == version, which holds everywhere else in the family. Scoped to the one feed:
  release.yml builds that URL from the same version it tags, and the appcast's shortVersionString, length
  and enclosure name are still checked against this release.
