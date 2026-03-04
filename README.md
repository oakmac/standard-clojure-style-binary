# Standard Clojure Style Binary

A small, fast, cross-platform native binary for formatting Clojure code according to [Standard Clojure Style].

Built by embedding [Lua 5.4] and the [Standard Clojure Style Lua library] into a minimal C program.
The entire binary is self-contained with no runtime dependencies and should be well under 5MB.

[Standard Clojure Style]:https://github.com/oakmac/standard-clojure-style-js
[Lua 5.4]:https://www.lua.org/
[Standard Clojure Style Lua library]:https://github.com/oakmac/standard-clojure-style-lua

## Why?

The [JavaScript implementation] of Standard Clojure Style works great and can be
used via `npx`, but it requires Node.js. The goal of this project is to produce
a native binary that can be distributed through system package managers like
Homebrew, apt, and Chocolatey — no runtime dependencies required.

A native binary is the expected form factor for these distribution channels, and
it makes Standard Clojure Style accessible to developers who don't have (or
don't want) a Node.js installation.

[JavaScript implementation]:https://github.com/oakmac/standard-clojure-style-js

## Technical Approach

This project uses a small C program that embeds the Lua 5.4 interpreter and
bundles the [Standard Clojure Style Lua library], which is a line-for-line port
of the JavaScript version and passes the same test suite.

Why C + Lua?

- **Tiny binary.** Lua 5.4 compiles to ~300-400KB. Combined with the SCS Lua
  source and a thin C wrapper, the total binary size should be 1-2MB.
- **Lua was designed for embedding.** This is one of its primary use cases and
  the tooling is mature.
- **Portable.** Lua is written in pure ANSI C and compiles on essentially every
  platform. Cross-compiling for macOS (Intel + Apple Silicon), Linux (x86_64 +
  ARM64), and Windows is straightforward.
- **Fast.** Lua is fast for a scripting language. For a code formatter where the
  bottleneck is file I/O, performance is more than sufficient.
- **Maintainable.** The Lua port is a line-for-line translation of the JavaScript
  version, making it easy to keep in sync as the formatting rules evolve.

### What is vendored

All dependencies are vendored into this repository:

- **Lua 5.4 source** — the complete Lua interpreter source code
- **Standard Clojure Style Lua** — the `standard-clojure-style.lua` single-file library
- **LuaFileSystem (lfs)** — for directory traversal and file metadata

No external downloads are needed to build the project.

### Architecture

```
main.c              — entry point: init Lua, pass argv, call into Lua
cli.lua             — CLI logic: arg parsing, file discovery, glob matching, config loading
vendor/
  lua-5.4.x/       — Lua interpreter source
  lfs/              — LuaFileSystem source
  standard-clojure-style.lua
```

The C layer is intentionally thin: initialize the Lua state, pass command-line
arguments, and call the Lua entry point. All CLI logic (argument parsing, file
discovery, glob matching, config file loading) lives in Lua.

## Command Line Usage

The `standard-clj` binary has the same interface as the [JavaScript CLI]:

```sh
# list files that would be formatted
standard-clj list src/

# check if files are already formatted (useful for CI)
standard-clj check src/

# format files in-place
standard-clj fix src/ test/ deps.edn

# read from stdin, write to stdout
echo '(ns my.app (:require [clojure.string :as str]))' | standard-clj fix -

# use glob patterns
standard-clj fix --include "src/**/*.{clj,cljs,cljc}"

# ignore specific files or directories
standard-clj fix src/ --ignore src/generated/

# use a config file
standard-clj fix --config .standard-clj.edn
```

See the [JavaScript CLI documentation] for full details on all commands and options.

[JavaScript CLI]:https://github.com/oakmac/standard-clojure-style-js#command-line-usage
[JavaScript CLI documentation]:https://github.com/oakmac/standard-clojure-style-js#command-line-usage

## Building from Source

### Prerequisites

A C compiler (gcc, clang, or MSVC) and `make`. That's it — everything else is vendored.

### Build

```sh
git clone https://github.com/oakmac/standard-clojure-style-binary.git
cd standard-clojure-style-binary

make

# optionally install to /usr/local/bin
sudo make install
```

### Build targets

```sh
make                  # build for the current platform
make clean            # remove build artifacts
make install          # install to /usr/local/bin (or PREFIX=/custom/path)
make test             # run the test suite
```

## Installation

### Homebrew (macOS and Linux)

```sh
brew tap oakmac/tap
brew install standard-clj
```

### apt (Debian / Ubuntu)

```sh
# Add the repository
curl -fsSL https://example.com/standard-clj/gpg.key | sudo gpg --dearmor -o /usr/share/keyrings/standard-clj.gpg
echo "deb [signed-by=/usr/share/keyrings/standard-clj.gpg] https://example.com/standard-clj/apt stable main" | sudo tee /etc/apt/sources.list.d/standard-clj.list

sudo apt update
sudo apt install standard-clj
```

### Chocolatey (Windows)

```
choco install standard-clj
```

### From a GitHub release

Download a prebuilt binary for your platform from the [Releases] page.

[Releases]:https://github.com/oakmac/standard-clojure-style-binary/releases

## Packaging Notes

This section documents how packages are built and published for each distribution channel.
It exists primarily as a reference for the maintainer.

### GitHub Releases

Every tagged release triggers a GitHub Actions workflow that cross-compiles
binaries for the following targets:

- `standard-clj-linux-x86_64`
- `standard-clj-linux-aarch64`
- `standard-clj-macos-x86_64`
- `standard-clj-macos-aarch64`
- `standard-clj-windows-x86_64.exe`

These are uploaded as release assets.

### Homebrew

The Homebrew formula lives in a separate tap repository: [oakmac/homebrew-tap].

The formula compiles from source using the release tarball:

```ruby
class StandardClj < Formula
  desc "Formatter for Clojure code using Standard Clojure Style"
  homepage "https://github.com/oakmac/standard-clojure-style-binary"
  url "https://github.com/oakmac/standard-clojure-style-binary/archive/refs/tags/vX.Y.Z.tar.gz"
  sha256 "..."
  license "ISC"

  def install
    system "make"
    bin.install "standard-clj"
  end

  test do
    output = shell_output("echo '( ns foo )' | #{bin}/standard-clj fix -")
    assert_includes output, "(ns foo)"
  end
end
```

To update the formula after a new release:

1. Tag and push a new release.
2. Update the `url` and `sha256` in the formula.
3. Push to the `oakmac/homebrew-tap` repository.

Users install with:

```sh
brew tap oakmac/tap
brew install standard-clj
```

Eventually, if there's enough usage, it may be worth submitting to `homebrew-core`
for inclusion in the main Homebrew repository.

[oakmac/homebrew-tap]:https://github.com/oakmac/homebrew-tap

### apt (Debian / Ubuntu)

Debian packages are built using `dpkg-deb`. The package structure is simple since
`standard-clj` is a single statically-linked binary with no dependencies:

```
standard-clj_X.Y.Z_amd64/
  DEBIAN/
    control
  usr/
    bin/
      standard-clj
```

The `DEBIAN/control` file:

```
Package: standard-clj
Version: X.Y.Z
Architecture: amd64
Maintainer: Chris Oakman <chris@oakmac.com>
Description: Formatter for Clojure code using Standard Clojure Style
 A fast, opinionated code formatter for Clojure with no configuration options.
Homepage: https://github.com/oakmac/standard-clojure-style-binary
```

Build the `.deb`:

```sh
dpkg-deb --build --root-owner-group standard-clj_X.Y.Z_amd64
```

For hosting the apt repository, the options include:

- **GitHub Pages + aptly** — use [aptly] to manage the repo locally and publish
  the static files to GitHub Pages.
- **Cloudflare R2 / S3** — host the repo files on object storage behind a CDN.
- **Gemfury or Packagecloud** — hosted services that manage apt repos for you.

[aptly]:https://www.aptly.info/

### Chocolatey (Windows)

Chocolatey packages for CLI tools are straightforward. The package contains the
Windows binary and a `.nuspec` metadata file:

```
standard-clj/
  standard-clj.nuspec
  tools/
    standard-clj.exe
```

The `.nuspec` file:

```xml
<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://schemas.microsoft.com/packaging/2015/06/nuspec.xsd">
  <metadata>
    <id>standard-clj</id>
    <version>X.Y.Z</version>
    <title>Standard Clojure Style</title>
    <authors>Chris Oakman</authors>
    <projectUrl>https://github.com/oakmac/standard-clojure-style-binary</projectUrl>
    <licenseUrl>https://github.com/oakmac/standard-clojure-style-binary/blob/main/LICENSE.md</licenseUrl>
    <tags>clojure formatter code-style</tags>
    <summary>A fast, opinionated code formatter for Clojure.</summary>
    <description>Formats Clojure code according to Standard Clojure Style. No configuration options.</description>
  </metadata>
  <files>
    <file src="tools\**" target="tools" />
  </files>
</package>
```

Build and publish:

```sh
choco pack standard-clj.nuspec
choco push standard-clj.X.Y.Z.nupkg --source https://push.chocolatey.org/
```

Chocolatey will automatically create a shim for `standard-clj.exe` so it's
available on the PATH.

## CI / Release Workflow

The intended release process:

1. Update the version number in the source.
2. Tag the release: `git tag vX.Y.Z && git push --tags`
3. GitHub Actions builds binaries for all platforms and creates a GitHub Release.
4. Update the Homebrew formula in `oakmac/homebrew-tap`.
5. Build and publish the `.deb` packages to the apt repository.
6. Build and publish the Chocolatey package.

Steps 4-6 can be automated via GitHub Actions as well.

## Related Projects

- [standard-clojure-style-js] — the original JavaScript implementation
- [standard-clojure-style-lua] — the Lua port (vendored here)
- Standard Clojure Style in Java — coming soon
- Standard Clojure Style in Python — planned

[standard-clojure-style-js]:https://github.com/oakmac/standard-clojure-style-js
[standard-clojure-style-lua]:https://github.com/oakmac/standard-clojure-style-lua

## License

[ISC License](LICENSE.md)