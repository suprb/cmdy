# Brand assets

`Assets/cmdy-logo-source.png` is the original artwork supplied for the cmdy
rebrand. Keep it unchanged as provenance for the current mark.

`Assets/cmdy-app-icon-source.svg` is the editable vector master for the current
app icon. Its lowercase `cmdy` lettering is outlined from Alpha Lyrae Medium;
the `c` uses stylistic set `ss01` and the final `y` uses `ss02` to carry the
same alternate-first/alternate-last rhythm as the reference lettering.

`Assets/cmdy-wordmark.svg` carries those same outlined `ss01` / `ss02`
alternates on a transparent canvas for the website header and footer.

`Assets/AlphaLyrae-Medium.woff2` is the unmodified upstream webfont used for
major website headings. It comes from Vega Protocol's Alpha Lyrae repository
at commit `d7d51ca6945aebeca57077320535362a959b2ca8` and is distributed under the
SIL Open Font License in `Assets/AlphaLyrae-LICENSE.md`.

`Assets/app-icon.png` is the rendered square 1024 px macOS icon master.

The app iconset generator reads `Assets/app-icon.png` from this directory.
The website build reads the same masters and copies them to the generated
`site/` output.

For a future name or logo change, keep `Assets/app-icon.png` as the stable build
input, archive the untouched new source artwork under a name-specific filename,
and follow the complete [rebranding runbook](../docs/REBRANDING.md).
