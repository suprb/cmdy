# The cmdy Platform

cmdy is a terminal first and a small programmable work platform second. Its
public model has three author-facing layers:

| Layer | Status | Job |
|---|---|---|
| **Extensions** | Shipped | Keep running: listen to semantic events, change bounded behavior, and show native interfaces. |
| **Actions** | Shipped | Run now: turn a script, command, or pane workflow into a native menu and palette item. |
| **Channels** | Shipped | Bring work in and send reviewed results back through capability-scoped connector Extensions. |

The short version is:

```text
Extensions add capabilities.
Actions perform work.
Channels move work in and out.
```

Read the implementation guides for [Extensions](EXTENSIONS.md),
[Actions](ACTIONS.md), and [Channels](CHANNELS.md).

## How the layers fit

```text
Slack / Telegram / webhook / another app
                    │
                    ▼
             Channel · Work Inbox
                    │
             review and route work
                    │
        ┌───────────┼────────────┐
        ▼           ▼            ▼
  read/complete    Agent        Shell
        │           │            │
        └───────────┼────────────┘
                    ▼
              Result · Outbox
                    │
                    ▼
          originating conversation

Extensions can contribute commands, policy, native Surfaces, companion apps,
and Channel connectors at the edges of this loop.
```

An Action is usually invoked by a person. An Extension is a resident process.
A Channel carries a work item across an application boundary and retains the
address needed for an optional reply. These are separate jobs, so authors can
choose the smallest layer that fits.

## Choose the smallest layer

| Need | Use |
|---|---|
| Run a script from a shortcut or palette entry | Action |
| Ask for inputs, confirmation, or several panes | Action |
| Observe command completion or pane lifecycle | Extension |
| Change a supported cmdy decision | Extension |
| Show a persistent tool or attached application | Extension |
| Receive a request from another application | Channel |
| Return progress or a result to the source thread | Channel |

A Channel connector is packaged as an Extension, but the user
experience is different enough to deserve its own name. People install an
Extension; they connect an account as a Channel; work appears in the Inbox.

## Supporting primitives

These are important, but they are not competing top-level authoring systems:

- **Surfaces** are native lists, tables, diffs, tasks, forms, and text rendered
  by cmdy for an Extension. Standard output remains canonical.
- **Workspaces** are real windows, tabs, panes, attached apps, and agent
  sessions. The public pane-composition API can gather existing live processes
  without restarting them.
- **Adaptive Frame** keeps the terminal sovereign while presenting the current
  tab group and Extension navigation on the left and contextual tools on the right.
  The tab sidebar and AppKit tab bar are mutually exclusive.
  Extensions contribute bounded native rows, never arbitrary views.
- **Marketplace** distributes Extensions, Channel connectors, themes, shaders,
  and rigs. `kind: channel` uses the ordinary capability-scoped Extension
  install pipeline.
- **Swarm** is a first-party reference Extension for finding agents and
  composing selected live agent panes into a workspace.

## No fourth layer yet

Schedules and event-driven rules are not a fourth product category or a current
feature plan. They should wait until the manual receive, route, and reply loop
has been proven in real use. Only then should cmdy decide whether durable
trigger, retry, audit, and cancellation semantics need a separate model at all.

Keeping this distinction avoids a platform vocabulary in which “action,”
“workflow,” “trigger,” and “command” all mean nearly the same thing.

## Trust model

The layers share a strict boundary:

- Personal Actions are user-owned executable code. Project Actions require
  explicit project trust.
- Extensions receive short-lived identity tokens with only their declared
  capabilities. Process exit revokes authority and removes owned resources.
- Channel messages and provider metadata are untrusted external data. Receiving a
  work item does not grant permission to execute it.
- A Channel routes work only through an explicit user choice in v1.
- Agent, shell, and manual results become previewable drafts. Sending is a
  separate explicit action; automatic replies do not exist in v1.

cmdy without Actions, Extensions, or Channels must remain a fast, complete
terminal. The platform adds leverage; it is not required scaffolding for the
base application.
