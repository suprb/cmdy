#!/usr/bin/env python3
"""Run with: cmdy extension dev this-file --capability channels --capability events.read"""

import os

from _cmdy import events, post

CHANNEL = os.environ["CMDY_EXTENSION_ID"] + ".inbox"


def deliver(reply):
    # A real connector calls Slack/Telegram/etc. here. Printing is the Demo
    # provider's delivery mechanism, so acknowledging success is truthful.
    print(f"outbound [{reply['conversationID']}]: {reply['body']}", flush=True)
    post(f"/v1/channel-replies/{reply['id']}/ack", {"delivered": True})


registration = post("/v1/channels", {
    "id": CHANNEL,
    "name": "Demo Inbox",
    "service": "Demo",
    "account": "local",
    "description": "A complete Receive / Route / Reply Channel",
    "replyCapabilities": ["reply"],
})

# Registration is also the lossless restart path for replies queued while the
# connector was offline or before its event stream attached.
for pending in registration.get("pendingReplies", []):
    deliver(pending)

post(f"/v1/channels/{CHANNEL}/work-items", {
    "id": "hello-channel",
    "deliveryID": "demo-delivery-v1",
    "conversationID": "demo-thread",
    "senderID": "demo-user",
    "senderName": "Demo Channel",
    "title": "Try the Work Inbox",
    "body": "Open Channels > Work Inbox. Start an agent, stage a shell command, or reply.",
})

for event in events():
    if event.get("kind") == "channel-reply":
        deliver(event)
