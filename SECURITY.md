# Security Policy

cmdy is a terminal, a process launcher, and a host for optional executable
Extensions. Security reports are taken seriously, especially when they cross a
trust boundary or could expose terminal content, credentials, files, or command
execution.

## Supported versions

Security fixes are made on the default branch and, when practical, released for
the most recent published version. Older builds are not maintained unless a
release note says otherwise. Please reproduce a report against the newest
available build before filing it when doing so is safe.

## Report a vulnerability

Use the repository's private **Security → Report a vulnerability** form to open
a GitHub Security Advisory. This keeps exploit details and reporter information
out of public issues.

Include as much of the following as is safe to share:

- the cmdy version or commit;
- macOS and hardware versions;
- the affected component and required configuration;
- minimal reproduction steps or a proof of concept;
- the impact you believe is possible; and
- any suggested mitigation or disclosure constraints.

Do not include tokens, credentials, private terminal output, personal paths, or
other people's data. If a report is not sensitive and does not describe an
exploitable vulnerability, use a regular GitHub issue instead.

We aim to acknowledge private reports within five business days. This is a
best-effort target, not a service-level agreement. Maintainers will validate the
report, agree on a disclosure plan, prepare a fix, and credit the reporter if
requested. Please do not publish exploit details before a coordinated release.

## Security boundaries

- The terminal engine and renderer do not load third-party code.
- The Extension API listens only on loopback and requires a per-launch bearer
  token. Every host route checks the Extension's declared capabilities.
- Loopback tokens block browser-origin requests, accidental clients, and other
  user accounts; they do not isolate cmdy from malicious unsandboxed code
  already executing as the same macOS user.
- Capabilities constrain the **cmdy host API**; they are not an operating-system
  sandbox. An installed Extension is executable code running as the current
  macOS user and must be reviewed like any other local program.
- Project Actions and Extensions require explicit project trust before they can
  run. Opening a repository alone must not execute project code.
- Extension exit or disablement revokes its launch token and removes the host
  resources owned by that launch.
- Channel content, terminal output, filenames, escape sequences, manifests, and
  marketplace metadata are untrusted input.
- Secret Channel settings belong in Keychain. Credentials must never be placed
  in manifests, logs, fixtures, screenshots, or issue reports.

The complete Extension trust model is documented in
[EXTENSION_PROTOCOL.md](EXTENSION_PROTOCOL.md). Architectural boundaries are
summarized in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Useful security reports

Examples include authentication or capability bypasses, path traversal,
untrusted project code running without consent, unsafe escape-sequence parsing,
token or credential disclosure, cross-Extension data access, extension-package
integrity failures, and unintended command execution.

A crash, unsupported configuration, or bug without a security impact belongs in
the public issue tracker. A malicious Extension doing what the user explicitly
installed it to do is outside cmdy's host security boundary, but a bundled or
Marketplace package that misrepresents its behavior is still worth reporting
privately.
