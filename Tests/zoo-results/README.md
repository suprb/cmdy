# Local zoo captures

`Tests/zoo.sh` and `Tests/zoo-focus.sh` write visual-diagnostics screenshots
here. Captures are intentionally ignored because terminal contents commonly
include usernames, hostnames, working directories, running processes, and
other machine-local state.

Use an explicit output directory when sharing sanitized evidence:

```sh
ZOO_OUT="$(mktemp -d /tmp/cmdy-zoo.XXXXXX)" ./Tests/zoo.sh
```

Review every image before publishing it. The automated correctness suite does
not depend on these screenshots.
