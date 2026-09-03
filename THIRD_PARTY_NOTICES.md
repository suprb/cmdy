# Third-party notices

cmdy is distributed under the MIT License in [`LICENSE`](LICENSE). That license
applies only to cmdy's original work. Third-party source, libraries, fonts, and
assets remain subject to their own copyright notices and license terms.

This file records the known direct dependencies and bundled assets in this
repository. It is not a substitute for the license files shipped by each
upstream project. A binary distributor should preserve every applicable notice
and should regenerate a dependency-license inventory whenever lockfiles change.

## Terminal engine ancestry: SwiftTerm

Active cmdy terminal-engine code includes code derived from SwiftTerm. The
following notice is preserved verbatim from the historical
`Vendor/SwiftTerm/LICENSE` file:

> Copyright (c) 2019-2022 Miguel de Icaza (https://github.com/migueldeicaza)
> Copyright (c) 2017-2019, The xterm.js authors (https://github.com/xtermjs/xterm.js)
> Copyright (c) 2014-2016, SourceLair Private Company (https://www.sourcelair.com)
> Copyright (c) 2012-2013, Christopher Jeffrey (https://github.com/chjj/)
>
> Permission is hereby granted, free of charge, to any person obtaining
> a copy of this software and associated documentation files (the
> "Software"), to deal in the Software without restriction, including
> without limitation the rights to use, copy, modify, merge, publish,
> distribute, sublicense, and/or sell copies of the Software, and to
> permit persons to whom the Software is furnished to do so, subject to
> the following conditions:
>
> The above copyright notice and this permission notice shall be
> included in all copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
> EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
> MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
> NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
> LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
> OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
> WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

Upstream: [migueldeicaza/SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)

## Website source and dependencies

Versions below are pinned by `site/package-lock.json`.

| Component | Use | License | Upstream license |
| --- | --- | --- | --- |
| React 19.2.7 and ReactDOM 19.2.7 | Runtime | MIT, Copyright Meta Platforms, Inc. and affiliates | [React license](https://github.com/facebook/react/blob/v19.2.7/LICENSE) |
| OGL 0.0.29 | Runtime WebGL library | MIT, Copyright 2018 oframe | [OGL package license](https://unpkg.com/ogl@0.0.29/LICENSE) |
| Vite 6.4.3 | Build tooling | Vite core is MIT. Its published artifact also records Apache-2.0, BSD-2-Clause, CC0-1.0, ISC, and MIT bundled dependencies. | [Vite license and bundled notices](https://github.com/vitejs/vite/blob/v6.4.3/LICENSE) |
| TypeScript 5.9.3 | Build tooling | Apache License 2.0 | [TypeScript license](https://github.com/microsoft/TypeScript/blob/v5.9.3/LICENSE.txt) |

### Codrops ASCII/OGL technique

The homepage ASCII shader adapts the glyph-bitmask technique from
[andrico1234/codrops-ascii-ogl](https://github.com/andrico1234/codrops-ascii-ogl).
The same notice is retained in `site/THIRD_PARTY_NOTICES.md`:

> MIT License
>
> Copyright (c) 2009-2024 Codrops
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all
> copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.

The implementation also uses OGL under the separate OGL license listed above.

### SRCL / Sacred Computer

Small website interface primitives are adapted from
[SRCL / Sacred Computer](https://github.com/internet-development/www-sacred).
Its exact MIT notice, including the copyright for INTERNET DEVELOPMENT STUDIO
COMPANY, is preserved in `site/THIRD_PARTY_NOTICES.md` and published with
the generated static site.

## Swift package dependencies

Versions below are pinned by `Vendor/BraincellBridge/Package.resolved` and
`Plugins/bridge/Package.resolved`.

| Component | Version | License | Upstream |
| --- | --- | --- | --- |
| swift-nio | 2.101.2 | Apache License 2.0; additional notices apply | [license](https://github.com/apple/swift-nio/blob/cd3e1152083706d77b223fb29110e590efcc70c0/LICENSE.txt), [NOTICE](https://github.com/apple/swift-nio/blob/cd3e1152083706d77b223fb29110e590efcc70c0/NOTICE.txt) |
| swift-atomics | 1.3.1 | Apache License 2.0 | [license](https://github.com/apple/swift-atomics/blob/0442cb5a3f98ab802acb777929fdb446bda11a34/LICENSE.txt) |
| swift-collections | 1.6.0 | Apache License 2.0 | [license](https://github.com/apple/swift-collections/blob/a0cb0954ecb21e4e31b0070e6ed5674e8556685a/LICENSE.txt) |
| swift-system | 1.7.2 | Apache License 2.0 | [license](https://github.com/apple/swift-system/blob/7502b711c92a17741fa625d722b0ccbd595d8ed1/LICENSE.txt) |

SwiftNIO's `NOTICE.txt` includes additional attributions for Netty, Node.js
llhttp, uSHET, FreeBSD/WIDE, swift-base64-kit, AsyncHTTPClient,
SwiftCertificates, Swift System, and Swift Package Manager. Preserve that
upstream notice with distributions that include SwiftNIO.

## Optional Chromium Embedded Framework payload

The optional Browser app edition can be built with Chromium Embedded Framework (CEF)
`145.0.28+g51162e8+chromium-145.0.7632.160`. CEF is BSD-licensed; its complete
license is tracked at `Plugins/chromium/CEF-LICENSE.txt`.

CEF's archive also contains generated notices for Chromium's third-party
components. `scripts/bootstrap-chromium.sh` verifies the pinned archive's
SHA-256 and installs both of these files with the optional framework payload:

- `Plugins/chromium/Frameworks/CEF-LICENSE.txt`
- `Plugins/chromium/Frameworks/CEF-CREDITS.html`

The bootstrap's `--check` mode fails when either notice is absent, and
Browser packaging preserves the complete `Frameworks/` directory inside the
signed app. The generated credits file is not duplicated in Git; it is
reproduced from the exact pinned upstream archive. See
`Plugins/chromium/CEF-NOTICE.md` for the payload and redistribution details.

Upstream: [Chromium Embedded Framework](https://github.com/chromiumembedded/cef)

## Bundled fonts

The native app bundles 35 font binaries under
`Kit/Sources/CmdyKit/Fonts/`. The marketing site additionally bundles Alpha
Lyrae and web builds of Geist Mono. Complete applicable terms and provenance
notices are stored locally as follows:

| Bundled family | Local terms and notices | License |
| --- | --- | --- |
| Alpha Lyrae | `Brand/Assets/AlphaLyrae-LICENSE.md`; `Brand/Assets/OFL-1.1.txt` | SIL Open Font License 1.1 with Reserved Font Name; the first file preserves upstream's copyright and additional notice, while the second supplies the normative OFL terms |
| Cascadia Mono | `Kit/Sources/CmdyKit/Fonts/CascadiaMono-LICENSE.txt` | SIL Open Font License 1.1 |
| Commit Mono | `Kit/Sources/CmdyKit/Fonts/CommitMono-LICENSE.txt` | SIL Open Font License 1.1 |
| Departure Mono | `Kit/Sources/CmdyKit/Fonts/DepartureMono-LICENSE.txt` | SIL Open Font License 1.1 |
| Fira Code | `Kit/Sources/CmdyKit/Fonts/FiraCode-LICENSE.txt` | SIL Open Font License 1.1 |
| Fixedsys Excelsior | `Kit/Sources/CmdyKit/Fonts/FixedsysExcelsior-NOTICE.md`; `Kit/Sources/CmdyKit/Fonts/CC0-1.0.txt` | Public-domain dedication / CC0 1.0 Universal |
| Fragment Mono | `Kit/Sources/CmdyKit/Fonts/FragmentMono-LICENSE.txt` | SIL Open Font License 1.1 |
| Geist Mono | `Kit/Sources/CmdyKit/Fonts/GeistMono-LICENSE.txt` | SIL Open Font License 1.1 |
| GlassTTY VT220 | `Kit/Sources/CmdyKit/Fonts/GlassTTYVT220-NOTICE.md`; `Kit/Sources/CmdyKit/Fonts/GlassTTYVT220-LICENSE.txt` | The Unlicense / public-domain dedication |
| Intel One Mono | `Kit/Sources/CmdyKit/Fonts/IntelOneMono-LICENSE.txt` | SIL Open Font License 1.1 |
| Iosevka Term | `Kit/Sources/CmdyKit/Fonts/IosevkaTerm-LICENSE.md` | SIL Open Font License 1.1 |
| JetBrains Mono | `Kit/Sources/CmdyKit/Fonts/JetBrainsMono-LICENSE.txt` | SIL Open Font License 1.1 |
| JuliaMono | `Kit/Sources/CmdyKit/Fonts/JuliaMono-LICENSE.txt` | SIL Open Font License 1.1 |
| M+ 1 Code | `Kit/Sources/CmdyKit/Fonts/MPlus1Code-LICENSE.txt` | SIL Open Font License 1.1 |
| Martian Mono | `Kit/Sources/CmdyKit/Fonts/MartianMono-LICENSE.txt` | SIL Open Font License 1.1 |
| Monaspace Argon, Krypton, Neon, Radon, and Xenon | `Kit/Sources/CmdyKit/Fonts/Monaspace-LICENSE.txt` | SIL Open Font License 1.1 with Reserved Font Names |
| Monocraft | `Kit/Sources/CmdyKit/Fonts/Monocraft-LICENSE.txt` | SIL Open Font License 1.1 |
| Pixel Code | `Kit/Sources/CmdyKit/Fonts/PixelCode-LICENSE.txt` | SIL Open Font License 1.1 |
| Server Mono | `Kit/Sources/CmdyKit/Fonts/ServerMono-LICENSE.md` | SIL Open Font License 1.1 |
| Ubuntu Sans Mono | `Kit/Sources/CmdyKit/Fonts/UbuntuSansMono-NOTICE.txt`; `Kit/Sources/CmdyKit/Fonts/UbuntuSansMono-LICENCE.txt` | Ubuntu Font Licence 1.0 |
| Nine Web437 faces | `Kit/Sources/CmdyKit/Fonts/Web437-NOTICE.md`; `Kit/Sources/CmdyKit/Fonts/CC-BY-SA-4.0.txt` | Creative Commons Attribution-ShareAlike 4.0 International |
| iA Writer Duo, Mono, and Quattro | `Kit/Sources/CmdyKit/Fonts/iAWriter-LICENSE.md` | SIL Open Font License 1.1 with Reserved Font Names |

`site/scripts/sync-brand.mjs` copies the Alpha Lyrae notices and Geist Mono
license into `site/public/fonts/`; Vite then copies them into `site/dist/fonts/`.
`site/scripts/verify-build.mjs` requires the generated release files.
`SacredPack-LICENSES.txt` is a provenance index for the fonts originally
discovered through the SACRED design system.

Code New Roman Nerd Font Mono is intentionally excluded: Nerd Fonts' own
[license audit](https://github.com/ryanoasis/nerd-fonts/blob/master/license-audit.md)
identifies the embedded Font Logos glyph set as unlicensed, so complete
redistribution rights could not be established.

## Redistribution

The repository's MIT License does not relicense any item above. When copying,
modifying, or redistributing cmdy, comply with the corresponding third-party
terms, including attribution, notice retention, Reserved Font Name, share-alike,
and source-form obligations where applicable.
