import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { createServer } from "vite";

const here = dirname(fileURLToPath(import.meta.url));
const website = resolve(here, "..");
const snapshotSource = await readFile(resolve(website, "public/marketplace-data.js"), "utf8");
const snapshotSandbox = { window: {} };
vm.runInNewContext(snapshotSource, snapshotSandbox, { filename: "marketplace-data.js", timeout: 1000 });

globalThis.window = { CMDY_MARKETPLACE_SNAPSHOT: snapshotSandbox.window.CMDY_MARKETPLACE_SNAPSHOT };
globalThis.document = { body: { dataset: {} }, documentElement: { style: {} } };
globalThis.localStorage = { getItem: () => null, setItem: () => undefined };

const vite = await createServer({
  root: website,
  appType: "custom",
  logLevel: "error",
  server: { middlewareMode: true }
});

try {
  const { App } = await vite.ssrLoadModule("/src/App.tsx");
  const { normalizeRegistry, safeURL } = await vite.ssrLoadModule("/src/pages/MarketplacePage.tsx");
  const expectations = {
    home: ["A terminal turned platform.", "Metal terminal", "Automatic window grid", "Grid ↔ splits", "Command intelligence", "Extensions", "Browser", "Detox", "Actions", "Channels", "Slack", "GitHub Issues", "RSS and Atom Feed", "Apple Reminders", "Updates", "Open source"],
    docs: ["cmdy Docs", "What cmdy is", "Choose one of three paths", "Extensions add capabilities", "option-as-meta", "cmdy action install-starters"],
    marketplace: ["Marketplace", "Package", "Type", "Description", "Install", "Demo Inbox", "Slack", "iMessage", "Apple Reminders"]
  };

  for (const [page, markers] of Object.entries(expectations)) {
    document.body.dataset.page = page;
    const markup = renderToStaticMarkup(React.createElement(App));
    assert.ok(markup.includes('class="cmdy-site theme-light"'), `${page}: shell did not render`);
    for (const marker of markers) {
      assert.ok(markup.includes(marker), `${page}: rendered markup is missing ${marker}`);
    }
    assert.ok(markup.includes('id="main-content"'), `${page}: missing main content landmark`);
    assert.ok(markup.includes('class="site-footer"'), `${page}: missing shared footer`);
    if (page === "home") {
      assert.ok(markup.includes('class="hero"'), "home: missing static editorial hero");
      assert.equal((markup.match(/class="hero-vid"/g) ?? []).length, 3, "home: expected one lead recording and two secondary recordings");
      assert.ok(markup.includes('class="hero-video-secondary-grid"'), "home: missing the two-column secondary recording grid");
      assert.ok(markup.includes('class="feature-inventory"'), "home: missing complete feature inventory");
      assert.ok(markup.includes('class="feature-list"'), "home: missing flat feature list");
      for (const clip of ["13-20", "08-12", "20-23"]) {
        assert.ok(markup.includes(`src="./hero-4x-${clip}.av1.mp4"`), `home: missing ${clip} AV1 demo source`);
        assert.ok(markup.includes(`src="./hero-4x-${clip}.h264.mp4"`), `home: missing ${clip} H.264 demo source`);
      }
      assert.ok(!markup.includes('class="hacker-backdrop"'), "home: cinematic backdrop should be unmounted");
      assert.ok(!markup.includes('class="signal-video"'), "home: video shader should be unmounted");
      assert.equal((markup.match(/class="feature-item"/g) ?? []).length, 25, "home: feature inventory must contain all 25 primary rows");
      assert.equal((markup.match(/class="feature-examples"/g) ?? []).length, 2, "home: Extensions and Channels must each list examples");
      assert.equal((markup.match(/class="feature-example"/g) ?? []).length, 11, "home: feature inventory must contain all 11 Extension and Channel examples");
      assert.equal((markup.match(/>Including</g) ?? []).length, 2, "home: Extensions and Channels must use the Including label");
      assert.ok(!markup.includes(">Examples<"), "home: feature inventory should not use the Examples label");
      for (const removed of ["Everything in cmdy.", "Terminal</h3>", "Windows + Workflow", "Intelligence</h3>", "Platform</h3>", "Your terminal. More capable.", 'class="closing-cta"']) {
        assert.ok(!markup.includes(removed), `home: removed feature chrome returned: ${removed}`);
      }
      const narrative = ["Metal terminal", "Sessions + Workspaces", "Keybinding import", "Automatic window grid", "Command intelligence", "Extensions", "Browser", "Detox", "Actions", "Channels", "Slack", "Apple Reminders", "Marketplace", "Updates", "Open source"];
      for (let index = 1; index < narrative.length; index += 1) {
        assert.ok(markup.indexOf(narrative[index - 1]) < markup.indexOf(narrative[index]), `home: narrative order is wrong near ${narrative[index]}`);
      }
    }
    assert.ok(!markup.includes('href="#"'), `${page}: contains an empty hash link`);
    const ids = [...markup.matchAll(/ id="([^"]+)"/g)].map((match) => match[1]);
    assert.equal(new Set(ids).size, ids.length, `${page}: contains duplicate element ids`);
    for (const image of markup.matchAll(/<img\b[^>]*>/g)) {
      assert.match(image[0], /\balt="[^"]*"/, `${page}: image is missing alt text`);
    }
    for (const link of markup.matchAll(/<a\b[^>]*target="_blank"[^>]*>/g)) {
      assert.match(link[0], /\brel="[^"]*noreferrer[^"]*"/, `${page}: new-window link is missing noreferrer`);
    }
    if (page === "docs") {
      for (const id of ["platform", "actions", "extensions", "surfaces", "channels", "config", "proof"]) {
        assert.ok(ids.includes(id), `docs: missing ${id} section`);
      }
      const narrative = ['id="model"', 'id="blocks"', 'id="platform"', 'id="extensions"', 'id="actions"', 'id="channels"', 'id="surfaces"'];
      for (let index = 1; index < narrative.length; index += 1) {
        assert.ok(markup.indexOf(narrative[index - 1]) < markup.indexOf(narrative[index]), `docs: narrative order is wrong near ${narrative[index]}`);
      }
    }
    if (page === "marketplace") {
      assert.ok(
        markup.includes("cmdy marketplace install dev.termite.demo-inbox"),
        "marketplace: stable Extension IDs must remain installable"
      );
      assert.ok(
        !markup.includes("cmdy marketplace install dev.cmdy."),
        "marketplace: must not cosmetically rewrite stable Extension IDs"
      );
      assert.ok(markup.includes('class="market-table"'), "marketplace: missing the package table");
      for (const removed of ["market-visual", "market-card", "market-grid", "registry-summary", "marketplace-hero", "market-trust", "What it actually does"]) {
        assert.ok(!markup.includes(removed), `marketplace: removed visual chrome returned: ${removed}`);
      }
    }
  }

  assert.throws(() => normalizeRegistry(null), /entries array/, "invalid registries must be rejected");
  const normalized = normalizeRegistry({
    featured: ["dev.example.channel", "missing"],
    entries: [
      { kind: "channel", id: "dev.example.channel", name: "Example", author: "A" },
      { kind: "channel", id: "dev.example.channel", name: "Duplicate" },
      { kind: "unknown", id: "bad", name: "Bad" }
    ]
  });
  assert.equal(normalized.entries.length, 1, "registry normalization must deduplicate and reject unknown kinds");
  assert.deepEqual(normalized.featured, ["dev.example.channel"], "featured entries must exist in the normalized catalog");
  assert.equal(safeURL("javascript:alert(1)"), "", "unsafe link protocols must be rejected");
  assert.equal(safeURL("https://example.com/project"), "https://example.com/project", "HTTPS project links must be retained");

  console.log("server-rendered all routes and passed Marketplace normalization/security smoke tests");
} finally {
  await vite.close();
}
