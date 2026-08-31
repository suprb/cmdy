#!/usr/bin/env python3
# Run with:
# cmdy extension dev 05_clean_paste.py --capability events.read --capability hooks
from _cmdy import events, post

post("/v1/hooks", {"id": "example.clean-paste", "boundary": "paste"})

for event in events():
    if event.get("kind") != "hook":
        continue
    text = event.get("text", "")
    clean = text.replace("“", '"').replace("”", '"').replace("’", "'")
    post(f"/v1/hook-responses/{event['request']}", {
        "decision": "replace" if clean != text else "continue",
        "value": clean,
    })
