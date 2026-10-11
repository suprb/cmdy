"""Pure exact launch/profile contract; no process, native, or user-state reads."""
from pathlib import Path
import hashlib
import json
import re
import shlex

from competitive_bench import terminal_config
from scroll_protocol import GRID, profile_overrides


def require(condition, message):
    if not condition:
        raise ValueError(message)


def config_text(terminal, options, cwd):
    return terminal_config(terminal, options, GRID, cwd) + "".join(
        line + "\n" for line in profile_overrides(terminal, options.profile))


def registered_configs(terminal):
    return {"cmdy-config/config" if terminal == "cmdy" else "ghostty.config", "zsh/.zshenv"}


def expected_environment(original_run, cwd, domain):
    return {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/zsh",
        "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "TMPDIR": str(cwd.parent) + "/",
        "ZDOTDIR": str(original_run / "zsh"), "XDG_CONFIG_HOME": str(original_run / "xdg-config"),
        "XDG_DATA_HOME": str(original_run / "xdg-data"), "XDG_CACHE_HOME": str(original_run / "xdg-cache"),
        "XDG_STATE_HOME": str(original_run / "xdg-state"), "CMDY_CONFIG_DIR": str(original_run / "cmdy-config"),
        "CMDY_DEFAULTS_DOMAIN": domain}


def validate_launch(run, metadata, launch, spec):
    """Validate retained bytes using original paths, including after relocation."""
    terminal = launch["terminal"]
    require(terminal in ("cmdy", "ghostty"), "unknown launch terminal")
    tooling = Path(metadata["toolingDirectory"])
    require(tooling.is_absolute() and tooling.name == "tooling" and ".." not in tooling.parts,
            "missing original frozen tooling directory")
    require(run.parent.name in ("calibration", "runs"), "launch is outside registered run directories")
    original_run = tooling.parent / run.parent.name / run.name
    relative_config = "cmdy-config/config" if terminal == "cmdy" else "ghostty.config"
    config = original_run / relative_config
    require(launch["config"] == str(config) and launch["readyPath"] == str(original_run / "fixture/ready.json"),
            "launch config/readiness belongs to another run")
    expected_argv = [metadata["binaries"][terminal]["path"]]
    if terminal == "ghostty":
        expected_argv += ["--config-default-files=false", f"--config-file={config}"]
    require(launch["arguments"] == expected_argv, "app launch or Ghostty isolation arguments changed")
    domain, cwd = launch["defaultsDomain"], Path(launch["cwd"])
    require(re.fullmatch(r"com\.cmdy\.bench\.[0-9a-f]{32}", domain) is not None
            and cwd.name == "work" and cwd.parent.parent == Path("/private/tmp")
            and re.fullmatch(r"cmdy-drain-[A-Za-z0-9_-]+", cwd.parent.name) is not None,
            "owned defaults domain or working directory unavailable")
    environment = launch["environment"]
    expected = expected_environment(original_run, cwd, domain)
    require(isinstance(environment, dict) and all(environment.get(k) == v for k, v in expected.items())
            and set(environment) <= set(expected) | {"HOME", "USER", "LOGNAME", "__CF_USER_TEXT_ENCODING"},
            "launch environment does not preserve profile isolation")
    socket = Path(spec["socketPath"])
    require(socket.name == "control.sock" and socket.parent.parent == Path("/private/tmp")
            and re.fullmatch(r"cmdy-scroll-[A-Za-z0-9_-]+", socket.parent.name) is not None,
            "unowned fixture control socket")
    command = [metadata["runtime"]["python"]["path"], "-S", str(tooling / "scroll_worker.py"),
               "--output", str(original_run / "fixture"), "--socket", str(socket),
               "--token", spec["token"], "--timeout", "600"]
    require(launch["fixtureCommand"] == command, "frozen fixture output/socket/command binding differs")
    require((run / "zsh/.zshenv").read_text() == "unsetopt RCS\nexec " + shlex.join(command) + "\n",
            "controlled shell fixture bytes differ from isolated launch")
    recorded = json.loads((run / "config-before-launch.json").read_text())
    require(set(recorded) == registered_configs(terminal), "missing registered launch configuration inputs")
    for name, expected_hash in recorded.items():
        require(hashlib.sha256((run / name).read_bytes()).hexdigest() == expected_hash,
                "launch configuration changed after registration")
    return domain
