#!/usr/bin/env python3
# Run with:
# cmdy extension dev 07_attention_switcher.py --capability events.read \
#   --capability commands --capability panes.read --capability panes.manage
from _cmdy import events, post, request

COMMAND = "example.focus-attention"
post("/v1/commands", {"id": COMMAND, "title": "Example: Focus attention pane"})

for event in events():
    if event.get("kind") != "command" or event.get("id") != COMMAND:
        continue
    panes = request("GET", "/v1/panes")["panes"]
    target = next((pane for pane in panes if pane.get("attention")), None)
    if target:
        post(f"/v1/panes/{target['id']}/focus")
