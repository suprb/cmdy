#!/usr/bin/env python3
# Run with:
# cmdy extension dev 06_quiet_notifications.py --capability events.read --capability hooks
from _cmdy import events, post

post("/v1/hooks", {"id": "example.quiet", "boundary": "notification", "priority": -10})

for event in events():
    if event.get("kind") != "hook":
        continue
    text = event.get("text", "")
    noisy = not text or text.lower() in {"done", "complete", "finished"}
    post(f"/v1/hook-responses/{event['request']}", {
        "decision": "cancel" if noisy else "continue",
    })
