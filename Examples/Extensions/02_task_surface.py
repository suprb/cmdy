#!/usr/bin/env python3
from _cmdy import events, post

COMMAND = "example.tasks"
post("/v1/commands", {"id": COMMAND, "title": "Example: Show task Surface"})

for event in events():
    if event.get("kind") == "command" and event.get("id") == COMMAND:
        post("/v1/surfaces", {
            "v": 1,
            "id": "example-tasks",
            "kind": "task",
            "title": "Release checks",
            "block": "last",
            "fallback": "Core: passed\nRenderer: running\nDocs: pending",
            "tasks": [
                {"id": "core", "label": "Core", "status": "passed", "durationMs": 318},
                {"id": "renderer", "label": "Renderer", "status": "running", "progress": 0.62},
                {"id": "docs", "label": "Docs", "status": "pending"},
            ],
        })
