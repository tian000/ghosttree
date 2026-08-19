# Ghosttree

Ghosttree is a macOS-native tool for creating fast, isolated copy-on-write views of directories. A ghosttree reads unchanged files directly from its lower directory, sends the first mutation of a path to a private upper directory, and represents deletions with whiteouts. The lower directory stays untouched.

The intended interface is deliberately generic:

```sh
ghosttree create --lower ~/src/project --name experiment
ghosttree list
ghosttree diff experiment
ghosttree destroy experiment --force
```

## Status

This repository is an early, compilable foundation—not yet a usable filesystem mount. It currently contains:

- a tested Swift overlay policy engine with lazy copy-up, merged directory listings, and whiteouts;
- persistent session creation, inspection, diffing, and deletion through the `ghosttree` CLI;
- a macOS app and FSKit file-system extension that compile against the macOS 26 SDK; and
- a safety gate that prevents the unfinished native adapter from mounting as a writable passthrough.

The next milestone is to connect FSKit vnode operations to `GhosttreeCore`, then add mount/unmount commands and a signed installer. Native path-backed FSKit file systems require macOS 26 or newer. The package-level policy engine and CLI build on macOS 15 for development.

## Architecture

Each session has three locations:

```text
lower/                  original directory; never mutated
session/upper/          files and directories created or copied up
session/whiteouts/      markers hiding lower-layer paths
```

Lookups prefer `upper`, reject any whiteouted path, then fall through to `lower`. Writes copy a lower file into `upper` before changing it. Directory enumeration merges both layers and removes whiteouted names.

`GhosttreeCore` contains this policy without depending on FSKit, which keeps it testable and allows other frontends later. `GhosttreeAppEx` is the native FSKit adapter.

## Build

Requirements: Xcode 26 and its command-line tools.

```sh
make test       # core and CLI tests
make build      # debug CLI
make app        # unsigned app + FSKit extension
```

Run the development CLI through Make:

```sh
make run ARGS="doctor"
```

To copy a release CLI into a custom prefix:

```sh
make install-cli PREFIX="$HOME/.local"
```

Session state defaults to `~/Library/Application Support/Ghosttree/Sessions`. Set `GHOSTTREE_HOME` or pass `--state-root` to use another directory.

## Installation target

The release goal is one signed, notarized `.pkg` (and a Homebrew cask) containing the app, extension, and CLI. Installing the CLI alone does not enable native mounts.

## License

Ghosttree is distributed under [LICENSE.txt](LICENSE.txt). The FSKit adapter began from Apple's “Building a passthrough file system” sample; its permissive license is retained in that file and source headers.
