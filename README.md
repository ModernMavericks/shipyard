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
