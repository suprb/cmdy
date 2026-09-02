import {
  Children,
  cloneElement,
  Fragment,
  isValidElement,
  type ReactElement,
  type ReactNode
} from "react";

const canonicalTerms = [
  "Andreas Pihlström",
  "Apple Reminders",
  "GitHub Issues",
  "iOS Simulator",
  "Window Inset",
  "Terminal maps",
  "Geist Mono",
  "Jira Cloud",
  "Mastodon Mentions",
  "Matrix Rooms",
  "Messages conversations",
  "Webhook Inbox",
  "RSS and Atom Feed",
  "IMAP Mail",
  "C ABI",
  "SHA-256",
  "Meta/Esc",
  "presses Return",
  "press Return",
  "and Return installs",
  "Escape restores",
  "Option combinations",
  "Shopify",
  "GitHub",
  "Apple",
  "Slack",
  "iMessage",
  "Claude",
  "Codex",
  "Pi",
  "Ghostty",
  "Kitty",
  "AppKit",
  "Keychain",
  "Chromium",
  "Simulator",
  "WebAudio",
  "Swift",
  "Metal",
  "Markdown",
  "Git",
  "Atom",
  "Discord",
  "Jira",
  "Linear",
  "Mastodon",
  "Matrix",
  "Telegram",
  "Pepto",
  "C64",
  "Dock",
  "macOS",
  "iOS",
  "iTerm2",
  "TUIs",
  "URLs",
  "IDs",
  "HTTPS",
  "IMAP",
  "SMTP",
  "MCP",
  "GPU",
  "SDK",
  "API",
  "RSS",
  "JSON",
  "SID",
  "CEF",
  "PTY",
  "OSC",
  "SSH",
  "HTML",
  "HTTP",
  "SSE",
  "ABI",
  "URL",
  "VT",
  "UI",
  "AI",
  "CI",
  "ID",
  "I"
] as const;

const orderedTerms = [...canonicalTerms].sort((left, right) => right.length - left.length);
const canonicalByLowercase = new Map(orderedTerms.map((term) => [term.toLocaleLowerCase(), term]));
const escapedTerms = orderedTerms.map((term) => term.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"));
const canonicalPattern = new RegExp(
  `(?<![\\p{L}\\p{N}_])(${escapedTerms.join("|")})(?![\\p{L}\\p{N}_])`,
  "giu"
);

type EditorialComponent = {
  editorialRaw?: boolean;
};

function canonicalForm(value: string): string {
  return canonicalByLowercase.get(value.toLocaleLowerCase()) ?? value;
}

export function editorialCaseString(value: string): string {
  const placeholders: string[] = [];
  const protectedValue = value.replace(canonicalPattern, (match) => {
    const index = placeholders.push(canonicalForm(match)) - 1;
    return `\uE000${index}\uE001`;
  });
  return protectedValue.toLocaleLowerCase().replace(/\uE000(\d+)\uE001/g, (_, index) => {
    return placeholders[Number(index)] ?? "";
  });
}

function editorialNode(node: ReactNode): ReactNode {
  if (typeof node === "string") {
    const output: ReactNode[] = [];
    let cursor = 0;
    let key = 0;
    for (const match of node.matchAll(canonicalPattern)) {
      const index = match.index ?? 0;
      if (index > cursor) output.push(node.slice(cursor, index));
      output.push(<span className="case" key={key}>{canonicalForm(match[0])}</span>);
      key += 1;
      cursor = index + match[0].length;
    }
    if (cursor < node.length) output.push(node.slice(cursor));
    return output.length ? output : node;
  }
  if (Array.isArray(node)) return Children.map(node, (child) => editorialNode(child));
  if (!isValidElement(node)) return node;

  const element = node as ReactElement<{ children?: ReactNode; className?: string }>;
  const type = element.type;
  const className = element.props.className ?? "";
  const isRawHost = typeof type === "string" && ["code", "kbd", "pre"].includes(type);
  const isRawComponent = typeof type !== "string"
    && Boolean((type as EditorialComponent).editorialRaw);
  if (isRawHost || isRawComponent || className.split(/\s+/).includes("case")) return element;
  if (element.props.children === undefined) return element;
  return cloneElement(element, undefined, editorialNode(element.props.children));
}

export function Case({ children }: { children: ReactNode }) {
  return <span className="case">{children}</span>;
}

export function EditorialText({ children }: { children: ReactNode }) {
  return <Fragment>{editorialNode(children)}</Fragment>;
}
