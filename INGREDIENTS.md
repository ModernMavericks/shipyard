# Build ingredients

Everything baked into what shipyard ships, and how a change to it reaches a release. shipyard **does**
compile: it builds CMake itself — shipped as `shipyard-cmake`, `shipyard-ctest` and `shipyard-cpack` —
and the Sparkle updater app, alongside the CMake modules and shell scripts it has always shipped. So
its build inputs are now both the things it compiles WITH and the things its scripts fetch on a
consumer's behalf.

This repo is consumed through a **moving** tag. Fifteen repos pin `@v1`, so anything merged here reaches
all of them within minutes — which is why the version is derived from the commit count (see
`scripts/shipyard-version.sh`) rather than bumped by hand.

| Ingredient | Pinned in | Renovate | On a bump |
|---|---|---|---|
| Sparkle 1.27.3 (updater framework) | `MavericksSparkle.cmake` (`mavericks_fetch_sparkle`) | ❌ **untrackable** by a standard manager: the version is a literal inside a CMake function, not a dependency declaration. Deliberate — Sparkle 1.x is the last line supporting 10.9, so a bump is a decision, not a routine update. | hand-edit, then the next push cuts a version like any other change |
| MacOSX10.9 SDK | `scripts/fetch_sdk.sh` (`MAVERICKS_SDK_URL` + `MAVERICKS_SDK_SHA256`, phracker/MacOSX-SDKs 11.3) | ❌ **untrackable**: pinned by SHA-256 against a frozen third-party release. There is no newer 10.9 SDK to move to; the pin exists to prove the bytes, not to track a stream. | n/a — a change here would mean a different SDK, which is a deliberate port decision |
| GitHub Actions (`actions/checkout@v7`, `actions/download-artifact@v8`, `actions/setup-python@v7`, `actions/upload-artifact@v7`, `softprops/action-gh-release@v3`) | `.github/workflows/*.yml` | ✅ native `github-actions` manager | automerges on green (`ship-if-green`), and the merge itself cuts the next shipyard version |
| `bats` (shell test driver) | installed by `.github/actions/install` from the platform package manager | ✅ tracked by the package manager, not pinned here | a new bats reaches CI on its next run; the suites are version-agnostic |
| CMake 4.4.3 (shipped as shipyard-cmake) | `cmake.pin` (version only) | ✅ Renovate customManager (github-releases Kitware/CMake) | `build-cmake.sh` verifies Kitware's published SHA-256; CI rebuilds the universal tree on a cache miss; the next push releases it |
| mavericks-clang 22.1.1-mavericks.1 (compiles shipyard-cmake's x86_64/10.9 half) | `mavericks-clang.pin` | ✅ Renovate customManager (github-releases ModernMavericks/clang, `-mavericks.N` compared) | CI installs the pinned cross pkg (SHA256SUMS-verified); a bump rebuilds shipyard-cmake on green |
| shipyard's own version | `UPSTREAM_VERSION` (the **line**) + `git rev-list --count` | n/a — first-party | every push to `main` cuts `<line>.<count>`; `@v1` moves to it |

No upstream release notes: shipyard is its own upstream -- it ports nothing, so there are no
someone-else's notes for a release to link.

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
