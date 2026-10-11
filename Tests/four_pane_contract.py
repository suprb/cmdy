"""Exact profile and isolation contract; pure configuration functions only."""
from pathlib import Path
import re
import shlex
from types import SimpleNamespace

from competitive_bench import terminal_config
from four_pane_evidence import require

ACTIONS = {
    "r": ("splitRight", "new_split:right"), "d": ("splitDown", "new_split:down"),
    "h": ("focusLeft", "goto_split:left"), "l": ("focusRight", "goto_split:right"),
    "k": ("focusUp", "goto_split:up"), "j": ("focusDown", "goto_split:down"),
    "e": ("equalizeSplits", "equalize_splits"),
    "u": ("resizeUp", "resize_split:up,10"), "n": ("resizeDown", "resize_split:down,10"),
    "i": ("resizeRight", "resize_split:right,10"), "o": ("resizeLeft", "resize_split:left,10"),
}
REQUIRED_TOOLING = {
    "four_pane_bench.py", "four_pane_worker.py", "four_pane_evidence.py", "four_pane_contract.py",
    "four_pane_parity_evidence.py", "FourPaneSetup.swift", "ScrollWindowGeometry.swift", "TerminalInputObserver.swift",
    "TerminalBenchWindow.swift", "competitive_bench.py", "parity_gate.py",
    "input-latency-bench.py", "terminal_bench_worker.py", "terminal_bench_pacing.py",
}


def expected_config(terminal, profile, cwd):
    result = terminal_config(terminal, SimpleNamespace(profile=profile, font_size=14), (120, 36), Path(cwd))
    if terminal == "ghostty":
        result += "unfocused-split-opacity = 1\n"
        result += "".join(f"keybind = cmd+ctrl+alt+{key}={action}\n" for key, (_, action) in ACTIONS.items())
    return result


def expected_bindings():
    return {"version": 1, "mappings": [
        {"shortcut": {"key": key, "modifiers": ["command", "control", "option"]},
         "command": {"type": "action", "value": command}, "source": "ghostty", "sourceAction": action,
         "importedAt": "2026-09-09T00:00:00Z"} for key, (command, action) in ACTIONS.items()], "history": []}


def validate_launch(run, metadata, launch, read):
    terminal, profile = launch["terminal"], metadata["profile"]
    config = Path(launch["config"])
    original_run = config.parent.parent if terminal == "cmdy" else config.parent
    require(original_run.is_absolute() and original_run.name == run.name, "launch config belongs to another run")
    relative_config = "cmdy-config/config" if terminal == "cmdy" else "ghostty.config"
    require(config == original_run / relative_config
            and (run / relative_config).read_text() == expected_config(terminal, profile, launch["cwd"]),
            "profile/font/configuration differs from the canonical contract")
    required_configs = {relative_config, "zsh/.zshenv"}
    if terminal == "cmdy":
        required_configs.add("cmdy-config/keybindings.json")
        require(read(run / "cmdy-config/keybindings.json") == expected_bindings(), "setup bindings changed")
    require(set(read(run / "config-before-launch.json")) == required_configs, "missing registered launch inputs")
    expected_argv = [metadata["binaries"][terminal]["path"]]
    if terminal == "ghostty":
        expected_argv += ["--config-default-files=false", f"--config-file={config}"]
    require(launch["arguments"] == expected_argv, "app launch or Ghostty isolation arguments changed")
    domain, cwd = launch["defaultsDomain"], Path(launch["cwd"])
    require(re.fullmatch(r"com\.cmdy\.bench\.[0-9a-f]{32}", domain) is not None
            and cwd.name == "work" and cwd.parent.parent == Path("/private/tmp")
            and cwd.parent.name.startswith("cmdy-drain-"), "owned defaults domain or working directory unavailable")
    expected_environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/zsh",
        "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "TMPDIR": str(cwd.parent) + "/",
        "ZDOTDIR": str(original_run / "zsh"), "XDG_CONFIG_HOME": str(original_run / "xdg-config"),
        "XDG_DATA_HOME": str(original_run / "xdg-data"), "XDG_CACHE_HOME": str(original_run / "xdg-cache"),
        "XDG_STATE_HOME": str(original_run / "xdg-state"), "CMDY_CONFIG_DIR": str(original_run / "cmdy-config"),
        "CMDY_DEFAULTS_DOMAIN": domain}
    environment = launch["environment"]
    require(all(environment.get(key) == value for key, value in expected_environment.items())
            and set(environment) <= set(expected_environment) | {"HOME", "USER", "LOGNAME", "__CF_USER_TEXT_ENCODING"},
            "launch environment does not preserve profile isolation")
    command = launch["fixtureCommand"]
    require(len(command) == 10 and command[:2] == [metadata["pythonExecutable"], metadata["workerSourcePath"]]
            and command[2] == "--output" and command[3] == str(original_run / "fixture")
            and command[4] == "--socket-directory" and command[6] == "--run-token"
            and command[8:] == ["--timeout", "120"], "unexpected fixture command")
    socket_directory = Path(command[5])
    require(socket_directory.parent == Path("/private/tmp") and socket_directory.name.startswith("cmdy-4p-")
            and re.fullmatch("[0-9a-f]{32}", command[7]) is not None, "unowned fixture control directory or token")
    require((run / "zsh/.zshenv").read_text() == "unsetopt RCS\nexec " + shlex.join(command) + "\n",
            "shell fixture bytes differ from its isolated launch")
    return {"domain": domain, "run": str(original_run), "cwd": str(cwd), "token": command[7]}
