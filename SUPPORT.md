# Support

cmdy is an open-source project maintained on a best-effort basis. The issue
tracker is the shared support channel: questions and answers there remain
searchable for the next person.

## Before opening an issue

1. Read the relevant section of the [README](README.md) and the focused guides
   for [Extensions](EXTENSIONS.md), [Actions](ACTIONS.md),
   [Channels](CHANNELS.md), and [releases](RELEASING.md).
2. Search open and closed issues for the error or behavior.
3. Retry with the newest build and the smallest configuration that reproduces
   the problem.
4. For Browser, Sim, Bridge, or MCP setup, run **Integration Doctor…** from the
   cmdy command palette and include its non-sensitive result.

Then choose the structured bug or feature template in GitHub Issues. For a
general usage question, open a bug report and select **Question / support** as
the affected area.

## What to include

- cmdy version or commit and how it was installed;
- macOS version, Mac model, and CPU architecture;
- exact reproduction steps, expected behavior, and actual behavior;
- whether the problem occurs with Extensions and custom configuration disabled;
- the smallest relevant config or Extension manifest; and
- focused logs, screenshots, or a short recording when they add evidence.

Replace usernames and personal paths with neutral placeholders. Remove shell
history, terminal output, tokens, credentials, repository secrets, and private
window content before posting. Do not upload an entire home or configuration
directory.

## Scope

The project can help with cmdy's terminal engine, renderer, native UI, bundled
features, documented protocols, public SDK, packaging, and first-party
Extensions. Maintainers may help isolate problems involving a shell, TUI,
third-party Extension, or external service, but those projects remain
responsible for their own behavior.

The source checkout currently requires macOS 26 and a matching Xcode toolchain.
The optional Chromium Extension additionally needs the separately documented CEF
payload; see [Plugins/chromium/README-CEF.md](Plugins/chromium/README-CEF.md).

## Security and conduct

Do not report vulnerabilities or private conduct incidents in a public issue.
Follow [SECURITY.md](SECURITY.md) or [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) and
use the repository's private GitHub Security Advisory form.
