# Standard Clojure Style Binary

A small, cross-platform native binary for formatting Clojure code according to [Standard Clojure Style].

Built by embedding [Lua] and the [Standard Clojure Style Lua library] into a
minimal C program. The entire binary is self-contained with no runtime
dependencies .

[Standard Clojure Style]:https://github.com/oakmac/standard-clojure-style-js
[Lua]:https://www.lua.org/
[Standard Clojure Style Lua library]:https://github.com/oakmac/standard-clojure-style-lua

## Project Status - 06 Mar 2026

This project works! You can clone the repo, type `make`, and get a small
(less than 1MB), self-contained binary with no runtime dependencies. If a tiny
binary size matters to you, this is a perfectly valid option.

However, the Lua interpreter is significantly slower than JavaScript JIT engines
(V8, JavaScriptCore) for the string-heavy workload of a code formatter. I
explored several options to close the performance gap, including LuaJIT, but
the end result was nothing close to the performance of a compiled [Bun] binary.

Most users will want the faster JS-compiled binary, which you can install via
Homebrew:

```sh
brew tap oakmac/tap
brew install standard-clj
```

This repo remains up as a reference for anyone interested in the approach of
embedding Lua in a C binary for CLI tools. The architecture works well and
could be a good fit for workloads that are less string-intensive.

[Bun]:https://bun.sh/

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

This project uses a small C program that embeds the Lua 5.5.0 interpreter and
bundles the [Standard Clojure Style Lua library], which is a line-for-line port
of the JavaScript version and passes the same test suite.

Why C + Lua?

- **Tiny binary.** Lua compiles to ~300-400KB. Combined with the SCS Lua
  source and a thin C wrapper, the total binary size should be 1-2MB.
- **Lua was designed for embedding.** This is one of its primary use cases and
  the tooling is mature.
- **Portable.** Lua is written in pure ANSI C and compiles on essentially every
  platform. Cross-compiling for macOS (Intel + Apple Silicon), Linux (x86_64 +
  ARM64), and Windows is straightforward.
- **Maintainable.** The Lua port is a line-for-line translation of the JavaScript
  version, making it easy to keep in sync as the formatting rules evolve.

### Architecture

```
main.c              — entry point: init Lua, pass argv, call into Lua
lua/cli.lua         — CLI logic: arg parsing, file discovery, glob matching, config loading
vendor/
  lua/              — [Lua v5.5.0](https://github.com/lua/lua/releases/tag/v5.5.0)
  standard-clojure-style.lua
  dkjson.lua
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

### From a GitHub release

Download a prebuilt binary for your platform from the [Releases] page.

[Releases]:https://github.com/oakmac/standard-clojure-style-binary/releases

### GitHub Releases

Every tagged release triggers a GitHub Actions workflow that cross-compiles
binaries for the following targets:

- `standard-clj-linux-x86_64`
- `standard-clj-linux-aarch64`
- `standard-clj-macos-x86_64`
- `standard-clj-macos-aarch64`
- `standard-clj-windows-x86_64.exe`

These are uploaded as release assets.

## Related Projects

- [standard-clojure-style-js] — the original JavaScript implementation
- [standard-clojure-style-lua] — the Lua port (vendored here)

[standard-clojure-style-js]:https://github.com/oakmac/standard-clojure-style-js
[standard-clojure-style-lua]:https://github.com/oakmac/standard-clojure-style-lua

## License

[ISC License](LICENSE.md)