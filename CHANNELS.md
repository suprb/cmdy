# cmdy Channels

> **Status: shipped in v1.** cmdy includes the Channel capability and HTTP
> protocol, typed Swift SDK models, a durable Work Inbox/Outbox, native menu and
> palette UI, agent and shell routing, a connector scaffold, and Marketplace
> support. Provider and local-workflow connectors are optional Marketplace
> Extensions; no account, credential, inbox, or external service is bundled or
> silently connected.

A **cmdy Channel** is a connection between an external work source and
cmdy. A connector normalizes a provider event into a reviewable Work Item.
The user can read, ignore, complete, send it to Agent Mode, or associate it with
one reviewed shell command. cmdy can then create a private result draft and,
only after an explicit send action, deliver that reply back through the owning
connector.

The model is:

> **Receive. Route. Reply.**

```text
Slack / Telegram / webhook / another app
                    │
                    ▼
        capability-scoped Channel Extension
                    │
                    ▼
              durable Work Inbox
                    │
          read · agent · shell · ignore
                    │
                    ▼
             private result draft
                    │
               user approves
                    ▼
          owning connector sends + acks
```

See [PLATFORM.md](PLATFORM.md) for how Channels relate to
[Extensions](EXTENSIONS.md) and [Actions](ACTIONS.md).

## What ships

- The `channels` Extension capability.
- Stable Channel ownership by Extension id and per-launch connection ownership
  by the short-lived Extension token.
- Durable state in `~/.config/cmdy/channels/state.json`; launch tokens are
  never persisted.
- Provider retry deduplication through `(channel, deliveryID)`.
- A native **Channels** menu, command-palette section, and Work Inbox.
- Explicit Work Item status transitions.
- Agent Mode routing. Every proposed command still waits for the user to press
  Return; the final summary becomes a private draft.
- Shell routing. The user writes one command, cmdy stages it without Return,
  and the matching semantic command block becomes a bounded private draft.
- Manual reply composition and a separate confirmation before send.
- Queued-reply recovery on connector registration and through polling.
- Typed Channel APIs in `Plugins/CmdySDK` and a standard-library Python
  protocol example in `Examples/Extensions/11_demo_channel.py`.
- Marketplace entries with `"kind": "channel"`, installed through the same
  reviewed native-Extension pipeline.

The first-party registry currently covers Slack, Telegram, Discord, Matrix,
iMessage, Mastodon, GitHub Issues, Linear, Jira Cloud, IMAP/SMTP, authenticated
webhooks, RSS/Atom, ntfy, Folder Drop, Clipboard Inbox, Git Watch, Command
Queue, Apple Reminders, and the credential-free Demo Inbox. Each connector is
separately installed and explicitly configured; read-only connectors omit the
reply event capability.

cmdy v1 does **not** auto-route incoming work, auto-run commands, auto-send
replies, download attachments, or provide provider accounts. Those boundaries
are intentional.

## Connector package

A connector is an ordinary cmdy Extension. Its manifest requests only what
it uses:

```json
{
  "manifestVersion": 1,
  "id": "com.example.slack",
  "name": "Example Slack Channel",
  "version": "1.0.0",
  "entrypoint": "connector",
  "capabilities": ["channels", "events.read"],
  "description": "Routes selected Slack work into cmdy",
  "guide": {
    "whatItDoes": ["Imports text from one selected Slack channel and posts approved replies in its threads."],
    "safety": ["Files are not downloaded and no reply is sent automatically."],
    "setup": ["Requires a narrowly scoped bot token and one channel ID."]
  }
}
```

`guide` is the factual explanation shown before install and from the Channels
window. State the provider data read, outbound boundary, allowlist or scope,
and required permission. cmdy supplies a conservative fallback for older
packages, but published connectors should describe their exact behavior.

The Channel id must equal the Extension id or extend it, for example
`com.example.slack.team`. This prevents one connector from impersonating
another. A live Extension launch can register at most 16 Channels, and cmdy
retains at most 256 Channel records overall.

Provider credentials remain the connector's responsibility and should live in
the macOS Keychain or the provider's secure credential store. Do not put OAuth
tokens in a manifest, Work Item, project repository, or terminal command.

Create a complete runnable connector:

```sh
cmdy channel new ./my-channel
cmdy extension validate ./my-channel
cmdy extension dev ./my-channel
```

The scaffold registers a Demo Channel, ingests one idempotent Work Item,
receives approved replies, and acknowledges delivery. Replace the marked Demo
receive/send functions with the provider SDK, webhook, or polling client.

## Work Item contract

Connectors submit a bounded provider event:

```json
{
  "id": "message-1712345",
  "deliveryID": "Ev123",
  "conversationID": "C123",
  "replyToID": "1712345.6789",
  "senderID": "U123",
  "senderName": "Mira",
  "title": "Run the staging migration",
  "body": "Please run the reviewed staging migration and report the result.",
  "createdAt": "2026-07-17T10:00:00Z",
  "projectHint": "~/src/api"
}
```

`deliveryID` must be the provider's immutable event/delivery identity. Retrying
the same delivery returns the existing Work Item instead of duplicating it.
`conversationID` and optional `replyToID` retain the provider address the
connector needs when a reply is approved.

cmdy adds `channel`, `receivedAt`, and a host-owned status:

```text
pending · accepted · working · needs-input · completed · failed · ignored
```

The Inbox holds at most 2,048 Work Items overall and 512 per Channel. Each body
is limited to 64 KiB and aggregate Work Item bodies to 8 MiB. Reply bodies have
the same 64 KiB item and 8 MiB aggregate bounds; durable state is read through
a 32 MiB ceiling. Terminal items and already-sent replies are pruned
oldest-first when space is needed. Active work, drafts, failed replies, and
queued deliveries are never silently pruned.

## Reply contract

A Channel advertises `replyCapabilities`. `reply` enables the v1 outbound
path; `update` and `upload` are reserved capability names and do not add a v1
provider operation by themselves.

Replies have a kind:

```text
acknowledgement · progress · question · result
```

and a delivery state:

```text
draft → queued → delivering → sent
                 │            └ failed → queued (explicit retry)
                 └ connector/host interruption → verification-needed
```

The critical boundary is state, not UI wording:

- Drafts are host-private. An Extension cannot list or receive them.
- A user action using the discovery credential moves a draft to `queued`.
- Only the currently connected owner gets the private `channel-reply` event.
- If it is offline, the reply remains queued and appears in the next
  registration response and `GET /v1/channel-replies`.
- Every delivery includes the original `conversationID` and optional
  `replyToID`, so restart recovery does not depend on connector-local state.
- Immediately before calling the provider, a modern connector persists the
  `delivering` boundary through `/attempt`. It then acknowledges delivered,
  failed, or explicitly `verification-needed`.
- A connector disconnect or host restart while `delivering` never silently
  requeues the message. cmdy changes it to `verification-needed` so the user
  can check the provider before accepting the duplicate risk of another send.
- Use the stable reply id as the provider idempotency key when the provider
  supports one. Legacy connectors may still acknowledge directly from queued,
  but do not receive the crash-safe provider-call boundary.
- A failed reply can be retried only through another explicit host/user action.
- A verification-needed reply requires an additional explicit confirmation
  before retry; it is never returned through queued recovery.

There is no automatic-send policy in v1.

## Agent mode versus shell mode

| | Agent Mode | Shell mode |
|---|---|---|
| User boundary | User chooses **Start Agent**. | User chooses **Use in Shell…** and writes the command. |
| Execution | Agent proposes one command; user reviews/edits and presses Return. | cmdy stages one command; user reviews/edits and presses Return. |
| Completion | Agent reports finished or failed. | The associated OSC 133 command block finishes. |
| Draft | Agent's bounded summary or failure reason. | Command, exit code, and at most 48 KiB of output. |
| Sending | Separate review and confirmation. | Separate review and confirmation. |

Incoming text is never pasted into the shell. In Agent Mode it is clearly
delimited as untrusted task context. In shell mode the user authors the command
that will handle it. Interactive programs, watchers, and daemons do not finish
until their associated command block exits; cmdy does not infer success from
arbitrary screen text. Closing the pane cancels staged work; transient
`accepted` and `working` states recover to `pending` after a host restart.

## Swift SDK

`Plugins/CmdySDK/Sources/CmdySDK/Channels.swift` provides typed models and
methods:

```swift
import CmdySDK

guard let cmdy = Cmdy() else { exit(1) }

let channel = CmdyChannel(
    id: "com.example.tasks.inbox",
    name: "Tasks Inbox",
    service: "Example Tasks",
    account: "team",
    replyCapabilities: [.reply]
)

cmdy.onEvent = { event in
    guard let reply = Cmdy.channelReply(from: event) else { return }
    cmdy.beginChannelReplyDelivery(reply.id) { claimed in
        guard claimed else { return }
        provider.send(
            reply.body,
            conversation: reply.conversationID,
            replyTo: reply.replyToID
        ) { result in
            cmdy.acknowledgeChannelReply(
                reply.id,
                delivered: result.isSuccess,
                error: result.failureReason
            )
        }
    }
}

cmdy.registerChannel(channel) { registration in
    for reply in registration?.pendingReplies ?? [] {
        // Deliver recovery replies through the same provider function.
    }
}

cmdy.ingestWorkItem(
    CmdyIncomingWorkItem(
        id: "task-42",
        deliveryID: "event-42",
        conversationID: "project-7",
        senderName: "Mira",
        title: "Check the release",
        body: "Run the release checks and report back."
    ),
    into: channel.id
)

cmdy.reportChannelHealth(
    CmdyChannelHealth(status: .healthy, lastSuccessAt: provider.checkedAt),
    for: channel.id
)

cmdy.listen()
RunLoop.main.run()
```

The SDK adds types and convenience only. The manifest grant and host routes are
the authority boundary, so Python, Rust, JavaScript, and Swift connectors have
the same power.

## HTTP API

Every route requires the normal local bearer token. “Extension” below means a
launched Extension token with `channels`; “discovery” means cmdy's
user-owned local controller credential.

| Method | Route | Authority | Purpose |
|---|---|---|---|
| `POST` | `/v1/channels` | Extension | Register/reconnect an owned Channel; returns queued recovery replies. |
| `GET` | `/v1/channels` | Either | Extension sees its own connected records; discovery sees all. |
| `GET` | `/v1/channels/<id>/health` | Either | Read provider health separately from process connectivity. |
| `DELETE` | `/v1/channels/<id>` | Owner or discovery | Remove the Channel and its host state. |
| `POST` | `/v1/channels/<id>/work-items` | Extension | Idempotently ingest external work. |
| `POST` | `/v1/channels/<id>/health` | Extension | Report bounded provider success, error, and retry status. |
| `GET` | `/v1/channel-work-items` | Either | List visible Work Items. |
| `PATCH` | `/v1/channel-work-items/<channel>/<item>` | Owner or discovery | Set a valid status. |
| `POST` | `/v1/channel-work-items/<channel>/<item>/replies` | Discovery | Create a draft; `send: true` is an explicit queue action. |
| `GET` | `/v1/channel-replies` | Either | Discovery sees all; Extension sees only its queued replies. |
| `DELETE` | `/v1/channel-replies/<id>` | Discovery | Discard a non-queued draft, failed reply, or completed record. |
| `POST` | `/v1/channel-replies/<id>/send` | Discovery | Queue a draft/retry; ambiguous retries require `confirmVerificationNeeded`. |
| `POST` | `/v1/channel-replies/<id>/attempt` | Extension | Persist the boundary immediately before an external provider send. |
| `POST` | `/v1/channel-replies/<id>/ack` | Extension | Mark provider delivery sent, failed, or verification-needed. |

Private SSE delivery uses `kind: "channel-reply"`; the semantic reply kind is
`replyKind` in that event because `kind` is the event discriminator. The Swift
SDK normalizes this detail.

Useful user-owned CLI commands:

```sh
cmdy channel list
cmdy channel items
cmdy channel replies
cmdy channel doctor [channel-id]
cmdy channel remove <channel-id> --yes
cmdy channel reply <channel-id> <work-item-id> "Finished and verified"
```

Stopping, disabling, or uninstalling a connector leaves its durable host state
available for recovery. Permanently remove it by choosing the offline Channel
in the **Channels** menu and confirming **Forget Channel**, or with
`cmdy channel remove`.

## Marketplace

Publish a connector as an Extension archive using `"kind": "channel"` in the
registry entry:

```json
{
  "kind": "channel",
  "id": "com.example.slack",
  "name": "Example Slack Channel",
  "description": "Selected Slack work in; reviewed results out",
  "author": "Example",
  "license": "MIT",
  "version": "1.0.0",
  "homepage": "https://github.com/example/cmdy-slack",
  "url": "https://github.com/example/cmdy-slack/releases/download/v1.0.0/cmdy-slack.zip",
  "sha256": "…",
  "capabilities": ["channels", "events.read"]
}
```

The archive and manifest rules are identical to other Extensions. cmdy also
verifies that a `channel` entry's manifest requests `channels`. Install still
requires native-code consent, validates archive paths and the manifest, checks
the pinned hash when supplied, signs the executable ad hoc, and launches it
with only declared capabilities. See [MARKETPLACE.md](MARKETPLACE.md).

After installation, **Channels → Configure Installed Channel…** renders the
registry's structured setup contract. Non-secret values are written to a private
`config.json`; secrets remain in macOS Keychain. Reconfiguration leaves blank
secret fields unchanged. cmdy starts the connector only for a bounded provider
health test and keeps it enabled only after it reports healthy; failed or timed-out
tests return it to the stopped state. CLI and bulk Channel installs also remain
stopped until this setup step is completed.

The registry seeds **Demo Inbox**, a credential-free local connector that
registers one Channel, adds a welcome Work Item, receives approved replies, and
acknowledges delivery. It is both a first-run tour and the smallest member of a
first-party catalog spanning provider APIs, feeds, local files and apps, and
explicit command adapters. Every package uses the same public protocol.

## Security boundary

- Message text, links, quoted history, sender names, and provider metadata are
  untrusted external data and possible prompt injection.
- A connector cannot invoke an Action, type into a pane, start an agent, or
  send a draft merely because it can receive Work Items.
- Work Item, Channel, reply, error, and command-output fields are bounded.
- Provider delivery IDs are deduplicated.
- One live launch owns a Channel at a time; disconnect revokes runtime access
  without deleting the durable Inbox.
- Launch tokens are not written to Channel state.
- Reply SSE events are private to the connector owner.
- Agent and shell result capture creates drafts; it never sends automatically.
- Extension exit disconnects all of its Channels and removes its ephemeral
  resources.

## Deliberate non-goals

Channels do not turn cmdy into a chat client, mirror all conversations,
execute incoming text, replace provider permissions, or require cloud
infrastructure. Automations, schedules, unattended routing, automatic replies,
attachment mirroring, bundled provider accounts, and silent discovery are not
part of v1. They should wait until the manual Receive / Route / Reply loop has
earned them.
