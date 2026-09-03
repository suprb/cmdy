# cmdy Plugins Are Now Extensions

“Plugin” was the original implementation name. The public product term is now
**Extension**:

- An **Extension** is installed behavior, a native mini app, a background tool,
  or an external companion such as Sim. Browser is instead an optional complete
  app edition because Chromium must remain sealed inside the signed bundle.
- The **cmdy SDK** is the optional toolbox used to build an Extension.
- A **Surface** is native UI an Extension asks cmdy to render.

Existing plugin folders, manifests, environment variables, and HTTP clients
remain compatible and migrate automatically.

Read the current guides:

- [PLATFORM.md](PLATFORM.md): Extensions, Actions, Channels, and the
  supporting primitives they share
- [EXTENSIONS.md](EXTENSIONS.md): start building
- [ACTIONS.md](ACTIONS.md): build one-shot commands and pane workflows
- [CHANNELS.md](CHANNELS.md): Channel SDK, durable Work Inbox, explicit Outbox,
  and Marketplace connector format
- [EXTENSION_PROTOCOL.md](EXTENSION_PROTOCOL.md): identity, capabilities,
  events, hooks, trust, lifecycle, and compatibility
- [SURFACE_PROTOCOL.md](SURFACE_PROTOCOL.md): native structured interfaces
