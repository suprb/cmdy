"""Validate public scripting metadata only; never inspects terminal implementation."""
import hashlib
from pathlib import Path
import plistlib
import xml.etree.ElementTree as ET


def validate_sdef(data: bytes) -> dict:
    root = ET.fromstring(data)
    commands = [item for item in root.iter("command") if item.get("name") == "input text"]
    terminals = [item for item in root.iter("class") if item.get("name") == "terminal"]
    if len(commands) != 1 or commands[0].get("code") != "GhstInTx" or len(terminals) != 1 or terminals[0].get("code") != "Gtrm":
        raise ValueError("published dictionary lacks compatible public input text/terminal codes")
    command, terminal = commands[0], terminals[0]
    direct = command.find("direct-parameter")
    targets = [item for item in command.findall("parameter") if item.get("name") == "to"]
    if direct is None or direct.get("type") != "text" or len(targets) != 1 or targets[0].get("code") != "GItT" or targets[0].get("type") != "terminal":
        raise ValueError("published input text parameter contract differs")
    ids = [item for item in terminal.findall("property") if item.get("name") == "id"]
    if len(ids) != 1 or ids[0].get("code") != "ID  " or ids[0].get("type") != "text":
        raise ValueError("published terminal ID is not stable text")
    return {"eventClass": "Ghst", "eventID": "InTx", "targetKeyword": "GItT",
            "terminalClass": "Gtrm", "idProperty": "ID  ", "directParameter": "text",
            "sha256": hashlib.sha256(data).hexdigest()}


def installed_definition(binary: Path) -> tuple[Path, dict]:
    contents = binary.resolve().parent.parent
    with (contents / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    name = info.get("OSAScriptingDefinition")
    if info.get("NSAppleScriptEnabled") is not True or not isinstance(name, str) or Path(name).name != name:
        raise ValueError("bundle does not publish an enabled scripting dictionary")
    if not name.endswith(".sdef"):
        name += ".sdef"
    path = contents / "Resources" / name
    return path, validate_sdef(path.read_bytes())
