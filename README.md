# shipyard

Build goop for Mac OS X 10.9 Mavericks.

Features: yes. Whatever helps native builds to succeed and cross builds to match.

## Install (once)

Install shipyard from the pkg. Download it from the latest release and install it:

```sh
gh release download -R ModernMavericks/shipyard --pattern '*.pkg'
sudo installer -pkg mavericks-shipyard-*.pkg -target /
```

It lands in `/usr/local/mavericks-shipyard` and registers with whatever cmake is on your `PATH`. It
also keeps itself current: its updater checks daily and installs each new release. The same pkg works
on Intel, on Apple Silicon and on 10.9.

With no cmake, the shell scripts still work and the CMake side is skipped with a message. To finish,
install any cmake, then run
`sh /usr/local/mavericks-shipyard/scripts/register-with-cmake.sh /usr/local/mavericks-shipyard`, or
wait for the next update, which runs the same step.

### Developing shipyard itself

`cmake --install` is for working on shipyard, not for consuming it. Install into a prefix whose `bin/`
is **not** on your `PATH`:

```sh
cmake -S . -B build
cmake --install build --prefix "$HOME/.local/opt/shipyard-dev"
```

That points your registry entry at the dev copy. Why not `~/.local` or the default `/usr/local`?
`find_package` searches prefixes derived from `PATH` before it reads the user package registry. A copy
under such a prefix (`~/.local` when `~/.local/bin` is on `PATH`, or `/usr/local`) would therefore go
on shadowing the pkg, even after the registry points back at it. The pkg points the registry back at
itself every time it installs or updates, so a dev copy stays in effect only until the next update.

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
  "include": ["/usr/local/mavericks-shipyard/mavericks-presets.json"],
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
