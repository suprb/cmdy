# Frozen public-API and historical ABI baselines

These files were emitted from the compiled, pre-replacement `CmdyGPU` and
`CmdyPTY` modules at repository ref
`584624985809f6000a82d3b3b97e43ef885af572`.

The canonical `*.symbols.json` files are normalized public symbol graphs. They
contain declarations and relationships, but no source locations, comments,
private storage layout, or function bodies. Those are the strict source-API
gate. The `*-historical-abi.json` files retain the old non-resilient layout for
provenance; private layout is not an equality target for a new implementation.

| File | SHA-256 |
| --- | --- |
| `CmdyGPU.symbols.json` | `244545f6712daae2f3a283defe78bf02bc245c813dbe4606e640431c78a285b1` |
| `CmdyGPU@Foundation.symbols.json` | `2210be4ace00656a12d9f28bdf799c136fddd7ac45255422f3e8b594e6481b33` |
| `CmdyPTY.symbols.json` | `7c2da13c9f26c5aa0e14a1564b4ad999109ea3fcd091c88b1962d7419fc9bc72` |
| `CmdyGPU-api.json` | `6fd0c411622a24fed5eeda8c9816c824f81f148a05a42e939356f322618bb565` |
| `CmdyPTY-api.json` | `aec244e62efbe88ce3e4c87879aeff8460eb9854f5b62139447b5349664e5daf` |
| `CmdyGPU-historical-abi.json` | `18606feab5d2caee0ff842f89df4587e879da0a719763a38eee1fbb77d75222c` |
| `CmdyPTY-historical-abi.json` | `71f8b3607508404366b1a8b875f158116720be523a172c95b7283de7dbd1ccea` |

Run `scripts/check-independent-api.sh` from any working directory. It builds
the current packages, extracts and canonicalizes public symbol graphs, and
requires an exact match. A mismatch is a compatibility review even if it is
additive.

The single reviewed normalization is the global underline-key rename from `SwiftTermUnderlineStyleKey` to `CmdyUnderlineStyleKey`. The gate requires exactly one variable of the frozen `NSAttributedString.Key` type on each side, strips spelling-dependent symbol IDs only for that pair, and compares everything else strictly. Further exceptions require an equally narrow, documented check; never add a broad ignored-declaration list.

To regenerate a baseline, first record a written reason and the reviewed API delta. Never silently update these files to make the gate pass.
