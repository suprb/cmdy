#!/usr/bin/env python3
from _cmdy import events, patch, post

opened = False
sequence = 0

for event in events():
    if event.get("kind") != "command-finished":
        continue
    row = {"id": event["block"], "cells": {
        "exit": event.get("exitCode", -1),
        "command": event.get("command", ""),
        "cwd": event.get("cwd", ""),
    }}
    if not opened:
        post("/v1/surfaces", {
            "id": "example-history", "kind": "table", "title": "Command history",
            "pane": event["pane"], "block": event["block"],
            "fallback": event.get("command", ""),
            "columns": [{"id": "exit", "title": "Exit", "width": 80},
                        {"id": "command", "title": "Command"},
                        {"id": "cwd", "title": "Directory"}],
            "rows": [row],
        })
        opened = True
    else:
        sequence += 1
        patch("/v1/surfaces/example-history", {
            "sequence": sequence, "upsertRows": [row],
            "summary": f"{sequence + 1} commands",
        })
