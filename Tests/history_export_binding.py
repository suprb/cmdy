"""Install and replay only the generated pilot's normal public shortcut stores."""
from __future__ import annotations

import json
from pathlib import Path

from history_export_protocol import ACTION, KEY_CODE, MODIFIER_FLAGS, SHORTCUT, digest, require
from history_export_phase import selected_action, SCREEN_ACTION


def cmdy_store_bytes(*, case=None, policy=None):
    # This is the public CMDYKeybindingStore v1 document. The headless dispatch
    # qualification decodes these exact bytes using the production store and
    # compares the mapping with a real public Ghostty-config import.
    action = selected_action(case, policy)
    document = dict(version=1, mappings=[dict(
        shortcut=dict(key="enter", modifiers=["control", "shift"]),
        command=dict(type="action", value="writeScreenPaste" if action == SCREEN_ACTION else "writeScrollbackPaste"),
        source="ghostty", sourceAction=action, importedAt="2026-09-12T00:00:00Z")], history=[])
    return (json.dumps(document, indent=2, sort_keys=True) + "\n").encode()


def shortcut_event(*, case=None, policy=None):
    return dict(shortcut=SHORTCUT, keyCode=KEY_CODE, modifierFlags=MODIFIER_FLAGS,
                eventTypes=["keyDown", "keyUp"], eventCount=2, autorepeat=0,
                intendedAction=selected_action(case, policy), actionInvocationVerified=False)


def binding_record(terminal, config_path, *, case=None, policy=None):
    action = selected_action(case, policy)
    config_path = Path(config_path)
    require(terminal in ("cmdy", "ghostty") and config_path.is_absolute()
            and config_path.is_file() and not config_path.is_symlink(), "invalid-owned-binding-config")
    lines = config_path.read_text().splitlines()
    if terminal == "cmdy":
        binding = config_path.parent / "keybindings.json"
        require(not any(line.strip().startswith("keybind") for line in lines),
                "cmdy-binding-must-use-public-store")
        require(binding.is_file() and not binding.is_symlink()
                and binding.read_bytes() == cmdy_store_bytes(case=case, policy=policy), "cmdy-public-binding-store-differs")
        storage = "CMDYKeybindingStore-v1"
    else:
        binding = config_path
        require([line.strip() for line in lines if line.strip().startswith("keybind")]
                == [f"keybind = {SHORTCUT}={action}"], "ghostty-public-binding-config-differs")
        storage = "ghostty-public-keybind-config"
    return dict(schemaVersion=1, terminal=terminal, storage=storage,
                configPath=str(config_path), configSHA256=digest(config_path.read_bytes()),
                bindingPath=str(binding), bindingSHA256=digest(binding.read_bytes()), **shortcut_event(case=case, policy=policy))


def install_binding(terminal, config_path, *, case=None, policy=None):
    action = selected_action(case, policy)
    config_path = Path(config_path)
    if terminal == "cmdy":
        binding = config_path.parent / "keybindings.json"
        with binding.open("xb") as stream:
            stream.write(cmdy_store_bytes(case=case, policy=policy))
        binding.chmod(0o600)
    elif terminal == "ghostty":
        with config_path.open("a") as stream:
            stream.write(f"scrollback-limit = 100000000\nkeybind = {SHORTCUT}={action}\n")
    else:
        raise ValueError("unknown-public-binding-terminal")
    return binding_record(terminal, config_path, case=case, policy=policy)


def validate_binding(terminal, config_path, receipt, *, case=None, policy=None):
    require(receipt == binding_record(terminal, config_path, case=case, policy=policy), "public-shortcut-binding-receipt-differs")
    return receipt
