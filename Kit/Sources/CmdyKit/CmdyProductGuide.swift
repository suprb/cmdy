import Foundation
import ProductIdentity

/// A small, factual description shared by Extensions, Actions, and Channels.
/// The three sections answer the questions that matter before enabling code:
/// what it changes, where authority stops, and what the user must configure.
public struct CmdyProductGuide: Equatable, Sendable {
    public let whatItDoes: [String]
    public let safety: [String]
    public let setup: [String]

    public init(whatItDoes: [String], safety: [String], setup: [String]) {
        self.whatItDoes = Self.clean(whatItDoes)
        self.safety = Self.clean(safety)
        self.setup = Self.clean(setup)
    }

    public var plainText: String {
        [
            Self.section("What it does", whatItDoes),
            Self.section("Safety", safety),
            Self.section("Setup", setup),
        ].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    public var jsonObject: [String: [String]] {
        ["whatItDoes": whatItDoes, "safety": safety, "setup": setup]
    }

    static func decode(_ json: Any?) -> CmdyProductGuide? {
        guard let json = json as? [String: Any] else { return nil }
        func strings(_ key: String) -> [String] {
            (json[key] as? [String] ?? []).map { String($0.prefix(1_024)) }
        }
        let guide = CmdyProductGuide(
            whatItDoes: strings("whatItDoes"),
            safety: strings("safety"),
            setup: strings("setup"))
        return guide.whatItDoes.isEmpty && guide.safety.isEmpty && guide.setup.isEmpty
            ? nil : guide
    }

    public static func marketplace(
        kind: String, id: String, name: String, description: String,
        channelMode: String?, setup: String?
    ) -> CmdyProductGuide {
        let product = ProductIdentity.current.titleName
        if let guide = firstParty[id] { return guide }
        if kind == "channel" {
            let canReply = channelMode == "two-way"
            return CmdyProductGuide(
                whatItDoes: [description],
                safety: [
                    "Provider content enters \(product) as untrusted Work Items; it is never executed as a command.",
                    canReply
                        ? "No reply is automatic. Only a reply you review and explicitly send can leave \(product)."
                        : "This Channel is read-only and does not advertise or deliver replies.",
                    "The connector is native code running as your macOS user with only its declared \(product) capabilities.",
                ],
                setup: [
                    setup.map { "Required: \($0)." }
                        ?? "Review the connector's configuration before enabling it.",
                    "Installation leaves the connector stopped until its configuration passes a live test.",
                ])
        }
        return CmdyProductGuide(
            whatItDoes: [description],
            safety: [
                "This is native Extension code that runs as your macOS user.",
                "\(product) grants only the capabilities declared by the installed manifest and checks them on every API route.",
                "Stopping the Extension revokes its token and removes the UI and commands it owns.",
            ],
            setup: [
                "Install it, review the installed capabilities and source, then enable it from Extensions.",
            ])
    }

    public static func localExtension(
        name: String, description: String, capabilities: [String], channel: Bool
    ) -> CmdyProductGuide {
        let product = ProductIdentity.current.titleName
        let grants = capabilities.isEmpty ? "No \(product) API capabilities are declared."
            : "Declared \(product) capabilities: \(capabilities.sorted().joined(separator: ", "))."
        return CmdyProductGuide(
            whatItDoes: [description],
            safety: [
                "This is local native code that runs as your macOS user.",
                grants,
                channel
                    ? "Incoming content is untrusted, and outbound delivery still requires explicit approval."
                    : "Stopping it revokes its \(product) token and removes the objects it registered.",
            ],
            setup: [channel
                ? "Review its config.json and test the provider connection before enabling it."
                : "Review its manifest and source, then use the Enabled switch to start it."],
        )
    }

    private static func clean(_ values: [String]) -> [String] {
        values.prefix(12).compactMap {
            let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : String(value.prefix(1_024))
        }
    }

    private static func section(_ title: String, _ values: [String]) -> String {
        guard !values.isEmpty else { return "" }
        return title + "\n" + values.map { "• \($0)" }.joined(separator: "\n")
    }

    private static let firstParty: [String: CmdyProductGuide] = {
        let product = ProductIdentity.current.titleName
        func channel(_ what: [String], _ safety: [String], _ setup: [String])
            -> CmdyProductGuide {
            CmdyProductGuide(
                whatItDoes: what,
                safety: safety + [
                    "Incoming content is untrusted and is never executed as a command.",
                ],
                setup: setup + [
                    "The connector remains stopped until configuration passes its live test.",
                ])
        }
        func twoWay(_ what: [String], _ safety: [String], _ setup: [String])
            -> CmdyProductGuide {
            channel(what, safety + [
                "Replies are off until configured and are sent only after you review and explicitly approve them.",
            ], setup)
        }
        return [
            "dev.cmdy.apple-reminders": channel([
                "Reads incomplete reminders from exact list names or IDs you allowlist and creates Work Items.",
                "It cannot create, edit, complete, or delete reminders.",
            ], [
                "The connector uses fixed, bounded JXA reads and deduplicates stable reminder IDs.",
            ], [
                "Choose at least one Reminders list and allow \(product) to read Reminders when macOS asks.",
            ]),
            "dev.cmdy.clipboard-inbox": twoWay([
                "Turns opt-in changes to the macOS text clipboard into Work Items; it has no clipboard history.",
                "An approved reply can replace the clipboard only when clipboard writing is separately enabled.",
            ], [
                "Clipboard reads are bounded to 64 KiB, and text written by the connector is suppressed from its own Inbox.",
            ], [
                "Enable clipboard polling; separately choose whether to include the current clipboard and allow approved writes.",
            ]),
            "dev.cmdy.command-queue": twoWay([
                "Polls one configured JSON-producing argv command for Work Items.",
                "Passes an approved reply as JSON on standard input to one configured consumer argv command.",
            ], [
                "Commands use fixed argv with no shell interpolation, bounded output, and bounded timeouts.",
            ], [
                "Provide non-empty producer and consumer argv arrays; bare command strings are rejected.",
            ]),
            "dev.cmdy.demo-inbox": channel([
                "Creates one local welcome Work Item and exercises Receive, Route, and Reply without an external account.",
                "Approved demo replies are printed by the local connector and acknowledged as delivered.",
            ], [
                "No provider, network credential, or personal data is required.",
                "No reply is automatic; only a reply you explicitly send is delivered to the local demo connector.",
            ], [
                "Install and enable it; there are no account settings.",
            ]),
            "dev.cmdy.discord": twoWay([
                "Polls text from allowlisted Discord channels or threads and posts approved replies to the source message.",
                "It does not download attachments or embeds and suppresses outbound mention parsing.",
            ], [
                "Discord snowflakes deduplicate inbound work; a stable enforced nonce protects reply recovery.",
            ], [
                "Create a narrowly permissioned bot, enable Message Content Intent if required, and add channel IDs plus its token.",
            ]),
            "dev.cmdy.folder-drop": twoWay([
                "Turns new or changed direct-child files in one folder into Work Items.",
                "Writes approved replies as mode-0600 JSON files in a separate outbox.",
            ], [
                "It does not recurse, follow symlinks, execute contents, or delete or move input files.",
            ], [
                "Choose narrow, separate inbox and outbox folders.",
            ]),
            "dev.cmdy.git-watch": channel([
                "Reads new commits from one local Git repository and creates Work Items.",
                "It runs only read-only git rev-parse, log, and show operations and cannot reply.",
            ], [
                "Existing commits form the baseline unless you explicitly import recent history.",
            ], [
                "Choose one repository; there is no home-directory or current-directory default.",
            ]),
            "dev.cmdy.github-issues": twoWay([
                "Imports open issues when first seen and new comments from allowlisted repositories; pull requests are ignored.",
                "Approved replies become comments on the originating issue.",
            ], [
                "Only allowlisted repositories can receive replies; attachments are not downloaded.",
            ], [
                "Use a fine-grained token with Metadata read and Issues read/write for only the selected repositories.",
            ]),
            "dev.cmdy.imap-mail": twoWay([
                "Polls one IMAP mailbox read-only over TLS and imports bounded plain-text message content.",
                "When SMTP is configured, approved replies are sent as mail; without SMTP the Channel is receive-only.",
            ], [
                "HTML and attachments are not imported, sent-message echoes are filtered, and stable IMAP IDs deduplicate work.",
            ], [
                "Configure the IMAP account and mailbox; add certificate-verified SMTP only if you want replies.",
            ]),
            "dev.cmdy.imessage": twoWay([
                "Reads allowlisted incoming text from the local Messages database and creates Work Items.",
                "It ignores messages sent by you, attachments, attributed-body archives, and existing history by default.",
            ], [
                "Database access is SQLite read-only and query-only; immutable Messages GUIDs deduplicate work.",
                "Approved sending uses constant AppleScript with the allowlisted target and body passed as separate arguments.",
            ], [
                "Grant \(product) Full Disk Access, then add at least one exact handle or chat GUID.",
                "Enable approved replies separately; macOS then asks for permission to control Messages.",
            ]),
            "dev.cmdy.jira": twoWay([
                "Imports issues and recent comments from exact Jira Cloud project keys and posts approved replies as comments.",
                "It supports atlassian.net Jira Cloud only; custom hosts and Jira Data Center are rejected.",
            ], [
                "Attachments are not downloaded, and ambiguous failed comment delivery requires you to check Jira before retrying.",
            ], [
                "Provide the Jira Cloud origin, account email, project keys, and a narrowly scoped API token.",
            ]),
            "dev.cmdy.linear": twoWay([
                "Imports recently observed Linear issues from allowlisted team or project UUIDs and posts approved comments.",
                "It can additionally restrict work to issues assigned to the API-key owner.",
            ], [
                "The issue scope is rechecked before every reply; authenticated attachments are not downloaded.",
            ], [
                "Add at least one team or project UUID and a personal API key; keep the scope narrow.",
            ]),
            "dev.cmdy.mastodon": twoWay([
                "Imports mention notifications from one Mastodon instance and posts approved replies to the original status.",
            ], [
                "Notification IDs deduplicate work and Mastodon's idempotency key protects reply recovery.",
            ], [
                "Provide the HTTPS instance URL and an access token allowed to read notifications and post statuses.",
            ]),
            "dev.cmdy.matrix": twoWay([
                "Syncs human text and emote events from allowlisted Matrix rooms and sends approved replies to their source event.",
                "It ignores unlisted rooms, notices, edits, media, and messages from the configured own user.",
            ], [
                "Matrix event and transaction IDs make receive and reply retries idempotent.",
            ], [
                "Provide an HTTPS homeserver, token, exact room IDs, and the verified own user ID.",
            ]),
            "dev.cmdy.ntfy": twoWay([
                "Polls allowlisted ntfy topics into Work Items.",
                "Approved replies publish only to one fixed reply topic, never to a topic selected by inbound data.",
            ], [
                "The reply topic must differ from subscribed topics; ambiguous publish failures may require a manual check before retry.",
            ], [
                "Set an HTTPS server and topic allowlist; optionally add a token and a separate reply topic.",
            ]),
            "dev.cmdy.rss-feed": channel([
                "Polls up to 16 RSS or Atom feeds, converts HTML to readable text, and creates read-only Work Items.",
                "It preserves links and cannot send replies.",
            ], [
                "Stable feed IDs deduplicate entries; downloads, entries, redirects, and text are bounded.",
            ], [
                "Add one or more HTTPS feed URLs; private feeds may use a Keychain bearer token.",
            ]),
            "dev.cmdy.slack": twoWay([
                "Polls new top-level text from one selected Slack channel and posts approved replies in the originating thread.",
                "It ignores bot/subtype messages, files, and existing thread replies.",
            ], [
                "Slack timestamps deduplicate inbound work and client message IDs protect outbound retries.",
            ], [
                "Create a bot with only the required history, chat, and users scopes; add its token and one channel ID.",
            ]),
            "dev.cmdy.telegram": twoWay([
                "Long-polls text and captions from allowlisted Telegram chats and sends approved replies to the source message.",
                "It does not need a public webhook and does not download media.",
            ], [
                "Update IDs deduplicate inbound work; check Telegram before retrying an ambiguous send failure.",
            ], [
                "Create a BotFather bot, add exact numeric chat IDs, and store the bot token.",
            ]),
            "dev.cmdy.webhook-inbox": twoWay([
                "Accepts authenticated JSON POSTs on a loopback receiver and turns them into idempotent Work Items.",
                "If configured, approved replies are POSTed to one fixed callback URL.",
            ], [
                "It never executes incoming text, requires an inbound secret, and rejects callback redirects.",
            ], [
                "Choose a port and inbound secret; optionally add one HTTPS callback and its token.",
            ]),
            "dev.cmdy.detox": CmdyProductGuide(whatItDoes: [
                "Adds a live-coding WebAudio synthesizer and an inline multi-line editor over the shell.",
                "Running the buffer starts audio; hiding the editor leaves audio playing until you stop it.",
            ], safety: [
                "Runs as native Extension code with events.read, commands, and ui.panels capabilities.",
                "Its editor buffer autosaves locally; disabling the Extension stops its owned commands and panel.",
            ], setup: [
                "Install and enable Detox, then open ‘Detox: Editor…’ from the command palette.",
            ]),
            "dev.cmdy.bridge": CmdyProductGuide(whatItDoes: [
                "Binds agent sessions to terminal panes and exposes session navigation from its menu-bar UI.",
                "Includes an MCP runtime so supported agents can inspect and type into bound panes.",
            ], safety: [
                "Requests events, pane read/type, commands, panels, and notifications—not pane lifecycle management.",
                "Typed input remains visible in the terminal; disabling Bridge revokes its token and removes its UI.",
            ], setup: [
                "Install and enable Bridge; register its bundled MCP shim with an agent client if automatic registration is unavailable.",
            ]),
            "dev.cmdy.chromium": CmdyProductGuide(whatItDoes: [
                "Adds a real Chromium browser as a docked companion beside the terminal.",
                "Its MCP shim lets an agent navigate, inspect, type, and capture the browser.",
            ], safety: [
                "Browser pages remain live external content; the Extension requests companion UI, pane typing, commands, hotkeys, events, and hooks.",
                "The Chromium framework is a large native payload and runs as your macOS user.",
            ], setup: [
                "Install the Extension and its verified Chromium payload, enable it, and register the bundled MCP shim with your agent client.",
            ]),
            "dev.cmdy.sim": CmdyProductGuide(whatItDoes: [
                "Attaches the iOS Simulator as a \(product) companion and adds build, run, and screenshot commands.",
                "Its MCP shim lets an agent drive those Simulator workflows.",
            ], safety: [
                "Requests events, pane typing, commands, hotkeys, panels, and companion UI.",
                "Build commands are typed into a visible terminal pane; Simulator access may trigger normal macOS permissions.",
            ], setup: [
                "Install and enable Sim with Xcode and an iOS Simulator available; register its bundled MCP shim with your agent client.",
            ]),
            "dev.cmdy.swarm": CmdyProductGuide(whatItDoes: [
                "Shows terminal and agent sessions together, lets you jump between them, and provides selected or all-agent workspaces.",
            ], safety: [
                "Requests events, pane read/manage, commands, hotkeys, panels, and surfaces.",
                "It can create and manage panes, but operates through \(product)'s capability-checked API and loses authority when stopped.",
            ], setup: [
                "Install and enable Swarm; its commands and session UI appear when agent sessions are present.",
            ]),
        ]
    }()
}
