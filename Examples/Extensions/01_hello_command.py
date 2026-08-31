#!/usr/bin/env python3
from _cmdy import events, post

COMMAND = "example.hello"
# Saving this file while `cmdy extension dev` runs restarts it cleanly.
post("/v1/commands", {"id": COMMAND, "title": "Example: Say hello"})

for event in events():
    if event.get("kind") == "command" and event.get("id") == COMMAND:
        post("/v1/notify", {
            "title": "Hello from an extension",
            "body": "This file is running outside the terminal core.",
        })
