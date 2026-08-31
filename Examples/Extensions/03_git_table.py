#!/usr/bin/env python3
import subprocess
from _cmdy import events, post

COMMAND = "example.git-table"
post("/v1/commands", {"id": COMMAND, "title": "Example: Git status table"})

for event in events():
    if event.get("kind") != "command" or event.get("id") != COMMAND:
        continue
    output = subprocess.run(
        ["git", "status", "--porcelain"], text=True, capture_output=True).stdout
    rows = []
    for index, line in enumerate(output.splitlines()):
        rows.append({"id": f"file-{index}", "cells": {
            "state": line[:2].strip() or "?", "path": line[3:]}})
    post("/v1/surfaces", {
        "id": "example-git", "kind": "table", "title": "Git status",
        "block": "last", "fallback": output or "Working tree clean",
        "columns": [{"id": "state", "title": "State", "width": 90},
                    {"id": "path", "title": "Path"}],
        "rows": rows,
    })
