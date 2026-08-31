#!/usr/bin/env python3
from _cmdy import events, post

COMMAND = "example.deploy-form"
post("/v1/commands", {"id": COMMAND, "title": "Example: Deploy form"})

for event in events():
    if event.get("kind") == "command" and event.get("id") == COMMAND:
        post("/v1/surfaces", {
            "id": "example-deploy", "kind": "form", "title": "Deploy",
            "block": "last", "fallback": "Choose a deployment environment",
            "fields": [
                {"id": "environment", "label": "Environment", "kind": "choice",
                 "value": "staging", "options": ["staging", "production"]},
                {"id": "reviewed", "label": "Plan reviewed", "kind": "toggle",
                 "value": False, "required": True},
            ],
            "actions": [{
                "id": "deploy", "title": "Deploy", "effect": "mutate",
                "style": "destructive",
                "confirmation": "Deploy the current commit to this environment?",
            }],
        })
    if event.get("kind") == "surface-action" and event.get("surface") == "example-deploy":
        post("/v1/notify", {"title": "Deploy request", "body": str(event.get("values", {}))})
