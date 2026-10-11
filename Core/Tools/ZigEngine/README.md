# Native library build and qualification

The normal `CmdyCore`, `CmdyGPU`, and internal `lib_cmdy` products use the Zig
native library. It owns terminal state, font preparation, shaping, rasterization,
cache and scheduling policies, and Metal command encoding. `Core/Platform`
contains mechanical Objective-C framework calls; embedded `.metal` files remain
Metal Shading Language. Swift supplies public API projections and macOS UI hooks.
Build the macOS app with `./build.sh -c release` from the repository root.
The wrapper prepares the pinned Zig compiler and source-hashed native archive
before invoking SwiftPM. The archive receipt binds the Zig sources, native
headers, platform shims, embedded shaders, and Apple SDK/Clang identities. The
old Swift engine and renderer sources are retained as comparison references and
excluded from the normal package graph.

Run the combined native, C client and Swift Core correctness suite in a fresh
evidence directory:

```sh
python3 Core/Tools/ZigEngine/qualify.py --output /tmp/cmdy-core-qualification
```

Optional `--corpus-dir /path/to/corpora` adds all eight retained 3 MB byte streams
as frozen correctness inputs. Timing is disabled by this runner. Its receipt
records input hashes, build modes, commands, process exits and any failure.
Native tests run in Debug and ReleaseSafe, including native storage ownership
and Unicode text projection. Swift tests run against the same ReleaseSafe
archive by default. Use a new output path for each attempt.

The pinned width generator is checked with
`python3 Core/Tools/ZigEngine/generate-unicode.py --check` after the upstream
`Core/Tools/UnicodeWidth/generate.py --check`. Grapheme boundaries have a
separate authenticated Unicode 16 generator in `Grapheme/`, matching the
existing Swift 6.2/macOS 26 text contract. Terminal width remains Unicode 17.

## Independent compatibility probes

These tools compare the Zig terminal with an **unchanged frozen production
Swift engine**. They measure semantic compatibility, not performance.

`prepare-reference.py` copies `Sources/CmdyCore` from the supplied frozen Core
directory, records every Swift input hash, and compiles it with
`SwiftReference.swift`. The probe is built in the same module so it can inspect
both screens and the existing internal engine state without editing Core.

`build-cases.py` creates deterministic cases from the retained CMDY regression
byte streams, recorded replay sessions, focused Unicode/margin/protocol cases,
mixed command histories, and host-message/reflow cases. The optional
`--performance-corpora` adds retained corpus bytes as correctness inputs; it
does not turn this into a timing benchmark.

`prepare-native.py` copies the current Zig source tree into a fresh directory,
pins every Zig file, and builds `NativeReference.zig` against that exact tree.
`run-probe.py` runs one exact binary with a pinned input, preserving partial
output and a process receipt if the run fails. Output directories must be new.

`compare.py` requires two completed successful runs, matching input hashes,
every case, and every requested checkpoint. It compares all captured fields,
including ordered callbacks; failures cannot be excluded or treated as passes.
It records the first 40 field differences per failing checkpoint while retaining
complete raw output for further diagnosis.

The JSON input is an array of objects:

```json
[{"name":"example","cols":7,"rows":4,"scrollback":8,"detailed":true,
  "steps":[{"op":"feed","bytes":[65,13,10],"checkpoint":true},
           {"op":"resize","cols":9,"rows":5}]}]
```

Supported operations are `feed`, `resize`, `viewport`, `host_message`, and
`reset`. The initial state and each requested checkpoint are captured. The
injected host clock always returns 1.25. No native application, PTY, system
clipboard, or network service is accessed.

The native host exposes every OSC dispatch. To observe the same public callback
in Swift, its probe registers handlers for every integer token in each case's
input bytes (including an optional sign), plus the parser's fallback selector
zero. This is a conservative superset of selectors reachable across feed
chunks, computed before execution without consulting candidate output. Every
native OSC event is retained and compared; callbacks are never filtered to
make the outputs agree. Hyperlinks are read from each engine's authoritative
link table, including entries no longer active on the pen.

Each state includes both buffers' geometry, tabs, saved cursor, complete retained
rows, wrapping/render metadata and images; terminal modes, pen, keyboard stacks,
links and title stacks; damage, blocks, graphics payloads/placements and ordered
host events. Each row SHA-256 covers every cell as signed 64-bit little-endian
integers, in this order:

```text
scalar, width, foreground, background, style, underline kind,
underline color (or -1), link id, extra scalar count (or -1), extra scalars...
```

Color encodings match the native ABI: default `0`, indexed `0x01000000 | index`,
RGB `0x02000000 | RGB`, inverted default `0x03000000`. `detailed: true` also
includes all cell arrays. Image payload SHA-256 covers exact encoded PNG/raw RGBA
bytes. Global version counters and randomly assigned render identities are not
compared across engines; subsystem tests must verify their identity, mutation,
snapshot and lifetime contracts independently.

Parser state and all four fast-path option values are also captured. Cases may
set `parser_delegate` to `owner`, `custom`, or `nil`, and `parser_options` to
`[coalesceASCII, decodeUTF8, batchUnicode, coalesceCSI]`. The custom delegate
records each original callback separately without applying terminal semantics;
this checks the owning feed's direct callbacks and weak-delegate boundaries.

`run-parser-differential.py` compares parser event packets and final states from
two exact executables using the retained parser byte corpus. It can compare the
native parser directly or the Swift facade linked to the real Zig parser ABI.
`ParserBridgeChecks.swift` supplies additional optimized Swift callback-lifetime
and reentry checks for that actual ABI, including weak receiver expiry and
retained argument arrays. An unused terminal identity stub may satisfy parser
type references in these standalone checks; its methods must trap if reached.

Typical invocation, with fresh evidence paths:

```sh
python3 Core/Tools/ZigEngine/prepare-reference.py \
  --frozen-core /path/to/frozen/Core --output /path/to/reference
python3 Core/Tools/ZigEngine/build-cases.py \
  --repo /path/to/cmdy-public --output /path/to/cases.json
python3 Core/Tools/ZigEngine/prepare-native.py \
  --source Core/Zig --output /path/to/candidate
python3 Core/Tools/ZigEngine/run-probe.py \
  --probe /path/to/reference/swift-reference --input /path/to/cases.json \
  --output /path/to/reference-run
python3 Core/Tools/ZigEngine/run-probe.py \
  --probe /path/to/candidate/native-reference --input /path/to/cases.json \
  --output /path/to/candidate-run
python3 Core/Tools/ZigEngine/compare.py \
  --input /path/to/cases.json --reference /path/to/reference-run \
  --candidate /path/to/candidate-run --output /path/to/comparison.json
```

The normal macOS app's rendering and model checks remain separate from these
engine probes. The renderer's text, shaping, public API, trace, and real Metal
pixel qualification is recorded in `ZIG-RENDERER-PORT.md` in the project's
private performance notes. Compatibility does not establish performance parity with another
terminal; use the unchanged performance policy for that comparison.
