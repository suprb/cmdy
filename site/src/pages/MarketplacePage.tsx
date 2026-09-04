import { useCallback, useEffect, useMemo, useState } from "react";
import { EditorialText } from "../components/EditorialCase";
import { browserInstallURL } from "../downloads";

const REGISTRY_URL = "https://raw.githubusercontent.com/suprb/cmdy-registry/main/registry.json";
const REGISTRY_REPO = "https://github.com/suprb/cmdy-registry";
const REGISTRY_FILES = `${REGISTRY_REPO}/blob/main/`;
const REGISTRY_RAW_FILES = "https://raw.githubusercontent.com/suprb/cmdy-registry/main/";
const kinds = ["shader", "theme", "rig", "patch", "channel", "plugin"] as const;
type Kind = typeof kinds[number];
type Filter = "all" | "featured" | Kind;
type Guide = { whatItDoes: string[]; safety: string[]; setup: string[] };

const labels: Record<Kind, string> = {
  shader: "Shader",
  theme: "Theme",
  rig: "Rig",
  patch: "Patch",
  channel: "Channel",
  plugin: "Extension"
};
const order: Record<Kind, number> = { shader: 0, theme: 1, rig: 2, patch: 3, channel: 4, plugin: 5 };

type Entry = {
  author: string;
  channelMode: string;
  description: string;
  file: string;
  guidedFields: number;
  guide: Guide;
  homepage: string;
  id: string;
  kind: Kind;
  license: string;
  name: string;
  setup: string;
  sha256: string;
  url: string;
  version: string;
};

type Registry = { entries: Entry[]; featured: string[] };
type LoadState = "checking" | "live" | "snapshot" | "error";

function value(raw: unknown, fallback: string, maximum = 500): string {
  return typeof raw === "string" && raw.trim() ? raw.trim().slice(0, maximum) : fallback;
}

function pinnedSHA256(raw: unknown): string {
  if (typeof raw !== "string") return "";
  const digest = raw.trim();
  return /^[0-9a-f]{64}$/i.test(digest) ? digest : "";
}

function publicBrandText(text: string): string {
  return text;
}

function publicPackageId(id: string): string {
  return id;
}

function guideLines(raw: unknown): string[] {
  if (!Array.isArray(raw)) return [];
  return raw.filter((line): line is string => typeof line === "string" && Boolean(line.trim()))
    .slice(0, 12).map((line) => publicBrandText(line.trim().slice(0, 1024)));
}

function entryGuide(item: Record<string, unknown>, kind: Kind, description: string, setup: string): Guide {
  const raw = item.guide && typeof item.guide === "object"
    ? item.guide as Record<string, unknown>
    : null;
  const parsed = {
    whatItDoes: guideLines(raw?.whatItDoes),
    safety: guideLines(raw?.safety),
    setup: guideLines(raw?.setup)
  };
  if (parsed.whatItDoes.length || parsed.safety.length || parsed.setup.length) return parsed;
  if (kind === "channel") {
    const twoWay = value(item.mode, "", 80) === "two-way";
    return {
      whatItDoes: [description],
      safety: [
        "Provider content enters cmdy as untrusted work items; it is never executed as a command.",
        twoWay
          ? "No reply is automatic. Only a reply you review and explicitly send can leave cmdy."
          : "This channel is read-only and cannot deliver replies.",
        "The connector is native code running as your macOS user with only its declared cmdy capabilities."
      ],
      setup: [setup ? `Required: ${setup}.` : "Review its configuration before enabling it.",
        "Installation leaves it stopped until configuration passes a live test."]
    };
  }
  if (kind === "plugin") {
    return {
      whatItDoes: [description],
      safety: [
        "This is native extension code that runs as your macOS user.",
        "cmdy grants only declared capabilities and checks them on every API route.",
        "Stopping the extension revokes its token and removes the UI and commands it owns."
      ],
      setup: ["Install it, review its capabilities and source, then enable it from extensions."]
    };
  }
  return {
    whatItDoes: [description],
    safety: ["This is a data package; it does not run as a native extension process."],
    setup: ["Install it with the visible command, then select it from cmdy."]
  };
}

export function normalizeRegistry(raw: unknown): Registry {
  if (!raw || typeof raw !== "object" || !Array.isArray((raw as { entries?: unknown }).entries)) {
    throw new Error("registry.json has no entries array");
  }
  const seen = new Set<string>();
  const entries: Entry[] = [];
  for (const candidate of (raw as { entries: unknown[] }).entries.slice(0, 5000)) {
    if (!candidate || typeof candidate !== "object") continue;
    const item = candidate as Record<string, unknown>;
    if (!kinds.includes(item.kind as Kind)) continue;
    const id = value(item.id, "", 180);
    const name = value(item.name, "", 180);
    if (!id || !name || seen.has(id)) continue;
    seen.add(id);
    const homepage = [item.homepage, item.repository, item.repo]
      .find((candidateValue) => typeof candidateValue === "string" && candidateValue.trim());
    const configuration = item.configuration && typeof item.configuration === "object"
      ? item.configuration as { version?: unknown; fields?: unknown }
      : null;
    const guidedFields = configuration?.version === 1 && Array.isArray(configuration.fields)
      ? Math.min(32, configuration.fields.filter((field) => field && typeof field === "object").length)
      : 0;
    const description = publicBrandText(value(item.description, "A community entry in the cmdy registry.", 800));
    const setup = publicBrandText(value(item.setup, "", 240));
    entries.push({
      author: publicBrandText(value(item.author, "unknown", 180)),
      channelMode: value(item.mode, "", 80),
      description,
      file: publicBrandText(value(item.file, "", 500)),
      guidedFields,
      guide: entryGuide(item, item.kind as Kind, description, setup),
      homepage: publicBrandText(value(homepage, "", 1000)),
      id,
      kind: item.kind as Kind,
      license: value(item.license, "unlisted", 120),
      name: publicBrandText(name),
      setup,
      sha256: pinnedSHA256(item.sha256),
      url: publicBrandText(value(item.url, "", 1000)),
      version: value(item.version, "0", 120)
    });
  }
  if (!entries.length) throw new Error("registry.json has no valid entries");
  const featuredRaw = (raw as { featured?: unknown }).featured;
  const featured = Array.isArray(featuredRaw)
    ? featuredRaw.filter((id): id is string => typeof id === "string" && seen.has(id)).slice(0, 24)
    : [];
  return { entries, featured };
}

export function safeURL(candidate: string): string {
  if (!candidate) return "";
  try {
    const parsed = new URL(candidate);
    return parsed.protocol === "https:" || parsed.protocol === "http:" ? parsed.href : "";
  } catch {
    return "";
  }
}

function registryFileURL(file: string): string {
  // Keep the public download surface as strict as the canonical registry
  // schema. Native archives are published only as flat dist/*.cmdyext files.
  if (!/^dist\/[a-z0-9][a-z0-9.-]*\.cmdyext$/.test(file)) return "";
  const segments = file.split("/");
  return `${REGISTRY_RAW_FILES}${segments.map(encodeURIComponent).join("/")}`;
}

export function entryDownloadURL(entry: Pick<Entry, "file" | "kind" | "sha256" | "url">): string {
  if (entry.kind !== "plugin" && entry.kind !== "channel") return "";
  if (!/^[0-9a-f]{64}$/i.test(entry.sha256)) return "";
  const packaged = registryFileURL(entry.file);
  if (packaged.toLowerCase().endsWith(".cmdyext")) return packaged;
  if (entry.file) return "";
  const external = safeURL(entry.url);
  if (external) {
    const parsed = new URL(external);
    if (parsed.protocol === "https:" && parsed.pathname.toLowerCase().endsWith(".cmdyext")) return external;
  }
  return "";
}

export function entryInstallURL(entry: Pick<Entry, "id" | "kind">): string {
  if (entry.kind !== "plugin" && entry.kind !== "channel") return "";
  if (!/^[A-Za-z0-9][A-Za-z0-9_-]*(?:\.[A-Za-z0-9][A-Za-z0-9_-]*)+$/.test(entry.id)) return "";
  return `cmdy://extension/install?id=${encodeURIComponent(entry.id)}`;
}

function entryLink(entry: Entry): string {
  const homepage = safeURL(entry.homepage);
  if (homepage) return homepage;
  if (entry.kind === "plugin" || entry.kind === "channel") return safeURL(entry.url) || REGISTRY_REPO;
  if (!entry.file || entry.file.split("/").includes("..")) return REGISTRY_REPO;
  const path = entry.file.split("/").filter(Boolean).map(encodeURIComponent).join("/");
  return path ? `${REGISTRY_FILES}${path}` : REGISTRY_REPO;
}

async function copyCommand(command: string): Promise<void> {
  if (navigator.clipboard && window.isSecureContext) {
    await navigator.clipboard.writeText(command);
    return;
  }
  const area = document.createElement("textarea");
  area.value = command;
  area.readOnly = true;
  area.style.position = "fixed";
  area.style.opacity = "0";
  document.body.append(area);
  area.select();
  const copied = document.execCommand("copy");
  area.remove();
  if (!copied) throw new Error("copy failed");
}

function MarketplaceRow({ entry, featured }: { entry: Entry; featured: boolean }) {
  const packageId = publicPackageId(entry.id);
  const command = `cmdy marketplace install ${packageId}`;
  const [copyState, setCopyState] = useState<"copy" | "copied" | "select">("copy");
  const copyLabel = { copy: "Copy", copied: "Copied", select: "Select" }[copyState];
  const downloadURL = entryDownloadURL(entry);
  const installURL = downloadURL ? entryInstallURL(entry) : "";
  const onCopy = async () => {
    try {
      await copyCommand(command);
      setCopyState("copied");
      window.setTimeout(() => setCopyState("copy"), 1500);
    } catch {
      setCopyState("select");
    }
  };
  return (
    <tr>
      <td className="market-package">
        <span className="market-package-line">
          <a className="case" href={entryLink(entry)} rel="noreferrer" target="_blank">{entry.name}</a>
          <small>v{entry.version}{featured ? " · featured" : ""}</small>
        </span>
      </td>
      <td className="market-type">{labels[entry.kind]}</td>
      <td className="market-description"><EditorialText>{entry.description}</EditorialText></td>
      <td className="market-install">
        <span className="market-install-inner">
          <code title={command}>{packageId}</code>
          <span className="market-install-actions">
            {installURL ? <a aria-label={`Install ${entry.name} in cmdy`} href={installURL}>Install in cmdy</a> : null}
            <button aria-label={`Copy install command for ${entry.name}`} onClick={onCopy} type="button">{copyLabel}</button>
            {downloadURL ? <a aria-label={`Download ${entry.name} package`} href={downloadURL} rel="noreferrer" title={`SHA-256: ${entry.sha256}`}>Download package</a> : null}
          </span>
        </span>
      </td>
    </tr>
  );
}

function snapshotRegistry(): Registry {
  return normalizeRegistry(window.CMDY_MARKETPLACE_SNAPSHOT);
}

export function MarketplacePage() {
  const [registry, setRegistry] = useState<Registry | null>(() => {
    try { return snapshotRegistry(); } catch { return null; }
  });
  const [loadState, setLoadState] = useState<LoadState>("checking");
  const [error, setError] = useState("");
  const [filter, setFilter] = useState<Filter>("all");
  const [query, setQuery] = useState("");
  const [attempt, setAttempt] = useState(0);

  const refresh = useCallback(() => setAttempt((value) => value + 1), []);

  useEffect(() => {
    const controller = new AbortController();
    const timer = window.setTimeout(() => controller.abort(), 12000);
    let active = true;
    let fallback: Registry | null = null;
    try {
      fallback = snapshotRegistry();
      setRegistry(fallback);
      setLoadState("checking");
    } catch {
      // A valid live registry can still recover a missing snapshot.
    }
    fetch(REGISTRY_URL, { signal: controller.signal, headers: { Accept: "application/json" } })
      .then((response) => {
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        return response.json();
      })
      .then(normalizeRegistry)
      .then((live) => {
        if (!active) return;
        setRegistry(live);
        setLoadState("live");
        setError("");
      })
      .catch((reason: unknown) => {
        if (!active) return;
        const message = reason instanceof Error ? reason.message : "Failed to fetch";
        setError(message);
        if (fallback) {
          setRegistry(fallback);
          setLoadState("snapshot");
        } else {
          setLoadState("error");
        }
      })
      .finally(() => window.clearTimeout(timer));
    return () => {
      active = false;
      window.clearTimeout(timer);
      controller.abort();
    };
  }, [attempt]);

  const featured = useMemo(() => new Set(registry?.featured ?? []), [registry]);
  const normalizedQuery = query.trim().toLocaleLowerCase();
  const entries = useMemo(() => (registry?.entries ?? []).filter((entry) => {
    const kindMatches = filter === "all" || (filter === "featured" ? featured.has(entry.id) : entry.kind === filter);
    const guide = [...entry.guide.whatItDoes, ...entry.guide.safety, ...entry.guide.setup].join(" ");
    const text = `${entry.name} ${entry.id} ${entry.description} ${entry.author} ${entry.kind} ${guide}`.toLocaleLowerCase();
    return kindMatches && (!normalizedQuery || text.includes(normalizedQuery));
  }).sort((left, right) => order[left.kind] - order[right.kind] || left.name.localeCompare(right.name)), [featured, filter, normalizedQuery, registry]);

  const filters: Array<[Filter, string]> = [
    ["all", "All"], ["featured", "Featured"], ["shader", "Shaders"], ["theme", "Themes"],
    ["rig", "Rigs"], ["patch", "Patches"], ["channel", "Channels"], ["plugin", "Extensions"]
  ];
  const stateLabel = loadState === "live" ? "Registry live"
    : loadState === "snapshot" ? "Bundled snapshot"
      : loadState === "error" ? "Registry offline" : "Checking registry";

  return (
    <div className="marketplace-page">
      <header className="marketplace-head page-shell">
        <div>
          <h1>Marketplace</h1>
          <p>{registry?.entries.length ?? 0} packages · {stateLabel}</p>
        </div>
        {error && loadState === "snapshot" ? <p className="market-status" title={error}>Live refresh unavailable</p> : null}
      </header>

      <section className="browser-extension page-shell" aria-labelledby="browser-extension-title">
        <div>
          <h2 id="browser-extension-title">Browser is an Extension</h2>
          <p>Install or remove it like any other Extension. Install downloads and verifies the notarized Browser build, then restarts cmdy; Remove restores the lean build and reclaims Chromium storage. Chromium and serve-sim stay inside the same real in-window Browser split.</p>
        </div>
        <a className="case" href={browserInstallURL}>Install Browser in cmdy</a>
      </section>

      <section className="market-toolbar page-shell" aria-label="Marketplace filters">
        <div className="filter-buttons">
          {filters.map(([id, label]) => (
            <button aria-pressed={filter === id} className={filter === id ? "selected" : ""} key={id} onClick={() => setFilter(id)} type="button">{label}</button>
          ))}
        </div>
        <input aria-label="Search marketplace" className="market-search" onChange={(event) => setQuery(event.currentTarget.value)} placeholder="Search packages" type="search" value={query} />
      </section>

      <section className="market-results page-shell">
        <div className="results-heading">
          <span>{filters.find(([id]) => id === filter)?.[1] ?? "All"}</span>
          <span>{entries.length} of {registry?.entries.length ?? 0}</span>
        </div>
        {loadState === "error" ? (
          <div className="registry-error">
            <h2>Registry unavailable</h2>
            <p>The public registry and bundled snapshot could not be read.</p>
            <code>{error || "Failed to fetch"}</code>
            <button onClick={refresh} type="button">Try again</button>
          </div>
        ) : entries.length ? (
          <div className="market-table-scroll">
            <table className="market-table">
              <thead><tr><th scope="col">Package</th><th scope="col">Type</th><th scope="col">Description</th><th scope="col">Install</th></tr></thead>
              <tbody>{entries.map((entry) => <MarketplaceRow entry={entry} featured={featured.has(entry.id)} key={entry.id} />)}</tbody>
            </table>
          </div>
        ) : (
          <div className="market-empty">
            <p>Nothing matches that filter yet.</p>
            <button onClick={() => { setFilter("all"); setQuery(""); }} type="button">Clear search</button>
          </div>
        )}
      </section>
    </div>
  );
}
