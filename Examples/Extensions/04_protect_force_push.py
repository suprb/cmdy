#!/usr/bin/env python3
# Run with:
# cmdy extension dev 04_protect_force_push.py --capability events.read --capability hooks
from _cmdy import events, post

post("/v1/hooks", {
    "id": "example.protect-force-push",
    "boundary": "command.submit",
    "priority": 20,
})

for event in events():
    if event.get("kind") != "hook":
        continue
    dangerous = event.get("command", "").startswith("git push --force")
    post(f"/v1/hook-responses/{event['request']}", {
        "decision": "cancel" if dangerous else "continue",
        "reason": "Use --force-with-lease after reviewing the remote branch." if dangerous else "",
    })
