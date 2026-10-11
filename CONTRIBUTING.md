# Contributing to cmdy

cmdy is a native macOS terminal with a narrow architectural point of view:
the terminal core stays small, fast, and correct; policy and native structured
UI are opened through isolated extensions.

Start with [BUILDING.md](BUILDING.md) and the
[architecture guide](docs/ARCHITECTURE.md). They define reproducible builds, ownership,
dependency direction, process boundaries, performance invariants, and the full
test matrix. Maintainer releases follow [RELEASING.md](RELEASING.md).

## Start here

Source development requires macOS 26+, Apple silicon, and Swift 6.2 / Xcode 26.

```sh
git clone https://github.com/suprb/cmdy.git
cd cmdy
./build.sh -c release
./test.sh
```

`build.sh` prepares Zig 0.15.2, verifies its download checksum when needed, and
builds the native archive before SwiftPM. You can point `CMDY_ZIG` at an existing
0.15.2 executable. Run `./build.sh` again after editing native engine, rendering,
platform bridge, or shader sources;
SwiftPM rejects an archive that no longer matches them.
When invoking SwiftPM directly after a native rebuild, add
`--manifest-cache none --disable-build-manifest-caching` so it selects the current immutable archive.
The build wrapper and standalone test runners include these flags.

Run the package suites relevant to the change before opening a pull request:

```sh
swift test --manifest-cache none --disable-build-manifest-caching --package-path Core -c release
swift test --manifest-cache none --disable-build-manifest-caching --package-path Renderer -c release
swift test --package-path Kit -c release
swift test --package-path Plugins/CmdySDK -c release
```

Build the app bundle with `./package.sh`. First-party Extensions and the website
are developed in a separate repository. Build your own Extensions with the public
SDK in `Plugins/CmdySDK` and the samples in `Examples/Extensions`.

## Boundaries

- Do not put third-party code, network work, or extension callbacks in PTY read,
  terminal-model mutation, or Metal frame paths.
- Preserve stdout and standard terminal behavior. Structured Surfaces are
  additive.
- Prefer an existing protocol primitive over a private first-party route.
- New extension authority requires a named capability and denial test.
- New Surface components need resource limits, text fallback, keyboard
  behavior, accessibility, and owner cleanup.
- Performance claims need a repeatable benchmark or gate.

## Protocol compatibility

Extension Protocol v1 and Surface Protocol v1 are public contracts.

- Adding optional fields, event kinds, or capabilities is compatible.
- Receivers ignore unknown optional fields.
- Removing or changing a field's meaning is breaking and requires a new route
  or protocol version.
- Legacy plugin paths, environment variables, and manifests remain supported
  through the documented v1 compatibility window.
- Machine schemas in `Schemas/` and typed models in CmdyKit and CmdySDK
  must change together.

## Changes

Keep changes scoped. Include focused tests proportional to the behavior and run
the relevant release suites. UI work should be inspected at normal, small, and
maximized window sizes. Never commit credentials, local discovery files,
compiled extension payloads, or code-signing identities.

By contributing, you agree that your contribution is licensed under the MIT
License in this repository.
