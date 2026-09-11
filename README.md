# shipyard

Build goop for Mac OS X 10.9 Mavericks.

Features: yes. Whatever helps native builds to succeed and cross builds to match.

## Install

```sh
cmake -S . -B build
cmake --install build --prefix "$HOME/.local"
```

## Use

In your `CMakeLists.txt`:

```cmake
project(foo LANGUAGES C OBJC)

find_package(MavericksShipyard REQUIRED)
include(Mavericks)

add_executable(foo ...)
mavericks_assert_binary_compatible(foo)
```

In your `CMakePresets.json`:

```json
{
  "version": 6,
  "include": ["$env{HOME}/.local/share/cmake/MavericksShipyard/mavericks-presets.json"],
  "configurePresets": [
    { "name": "native", "inherits": "mavericks-native" },
    { "name": "cross",  "inherits": "mavericks-cross"  }
  ]
}
```

In your `.github/workflows/*.yml` (if applicable):

```yaml
- uses: ModernMavericks/shipyard/.github/actions/install@v1
```

Then build:

```sh
cmake --preset native    # on Mavericks
cmake --preset cross     # on Tahoe
```

## Sparkle

Configure a keypair with
[ed25519](https://github.com/ModernMavericks/ed25519).

In your `CMakeLists.txt`:

```cmake
include(MavericksSparkle)
mavericks_add_updater_app(
  NAME          FooUpdater
  BUNDLE_ID     com.example.FooUpdater
  FEED_URL      https://github.com/you/foo/releases/latest/download/appcast.xml
  ICON          updater/foo.icns
  CONFIRM_TITLE "Foo updated"
  CONFIRM_BODY  "Foo was updated in the background."
)
```

## Conventions for Claude Code

The family's conventions ship as the `modernmavericks` Claude Code plugin, from this repo's
marketplace. A product repo's checked-in `.claude/settings.json` registers the marketplace and
enables the plugin, but that alone installs nothing. Install it once, for every family repo:

```sh
claude plugin install modernmavericks@modernmavericks --scope user
```

then turn on auto-update in `/plugin` → Marketplaces → modernmavericks. The plugin carries no
version, so every push to `main` is an update.
