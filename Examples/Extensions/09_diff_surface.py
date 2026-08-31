#!/usr/bin/env python3
import subprocess
from _cmdy import events, post

COMMAND = "example.diff"
post("/v1/commands", {"id": COMMAND, "title": "Example: Working tree diff"})

for event in events():
    if event.get("kind") != "command" or event.get("id") != COMMAND:
        continue
    diff = subprocess.run(["git", "diff", "--no-ext-diff"],
                          text=True, capture_output=True).stdout
    post("/v1/surfaces", {
        "id": "example-diff", "kind": "diff", "title": "Working tree",
        "block": "last", "fallback": diff or "No changes",
        "diff": diff or " No changes",
    })
