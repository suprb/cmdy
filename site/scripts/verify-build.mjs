import { access, readFile } from "node:fs/promises";
import { constants } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const here = dirname(fileURLToPath(import.meta.url));
const site = resolve(here, "../dist");
const pages = [
  ["index.html", "home"],
  ["docs.html", "docs"],
  ["marketplace.html", "marketplace"]
];

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

async function exists(path) {
  try {
    await access(path, constants.R_OK);
    return true;
  } catch {
    return false;
  }
}

const referencedAssets = new Set();
for (const [file, page] of pages) {
  const path = resolve(site, file);
  const html = await readFile(path, "utf8");
  assert(html.startsWith("<!doctype html>"), `${file}: missing doctype`);
  assert(html.includes(`data-page="${page}"`), `${file}: wrong page identity`);
  assert(html.includes('<div id="root"></div>'), `${file}: missing React root`);
  assert(!html.includes("/src/"), `${file}: contains a development source path`);
  assert(!/(style\.css|marketplace\.css|marketplace\.js)/.test(html), `${file}: references a retired asset`);
  for (const match of html.matchAll(/(?:src|href)="(\.\/[^"#?]+)"/g)) {
    referencedAssets.add(match[1].replace(/^\.\//, ""));
  }
}

for (const asset of referencedAssets) {
  assert(await exists(resolve(site, asset)), `missing local asset: ${asset}`);
}

for (const asset of [
  "app-icon.png",
  "cmdy-wordmark.svg",
  "fonts/AlphaLyrae-Medium.woff2",
  "fonts/AlphaLyrae-LICENSE.md",
  "fonts/OFL-1.1.txt",
  "fonts/GeistMono-Regular.woff2",
  "fonts/GeistMono-Medium.woff2",
  "fonts/GeistMono-LICENSE.txt",
  "THIRD_PARTY_NOTICES.md",
  "hero-poster.jpg",
  "hero-4x-13-20.av1.mp4",
  "hero-4x-13-20.h264.mp4",
  "hero-4x-08-12.av1.mp4",
  "hero-4x-08-12.h264.mp4",
  "hero-4x-20-23.av1.mp4",
  "hero-4x-20-23.h264.mp4",
  "shopify-bag-black.svg"
]) {
  assert(await exists(resolve(site, asset)), `missing application asset: ${asset}`);
}

const websiteNotices = await readFile(resolve(site, "THIRD_PARTY_NOTICES.md"), "utf8");
for (const marker of [
  "Copyright (c) 2009-2024 Codrops",
  "Copyright (c) 2024 INTERNET DEVELOPMENT STUDIO COMPANY",
  "The Shopping Bag are trademarks of Shopify Inc."
]) {
  assert(websiteNotices.includes(marker), `website notices are missing: ${marker}`);
}

for (const retired of ["style.css", "marketplace.css", "marketplace.js"]) {
  assert(!(await exists(resolve(site, retired))), `retired asset is still published: ${retired}`);
}

const snapshotSource = await readFile(resolve(site, "marketplace-data.js"), "utf8");
const sandbox = { window: {} };
vm.runInNewContext(snapshotSource, sandbox, { filename: "marketplace-data.js", timeout: 1000 });
const snapshot = sandbox.window.CMDY_MARKETPLACE_SNAPSHOT;
assert(snapshot && Array.isArray(snapshot.entries), "Marketplace snapshot has no entries array");
assert(snapshot.entries.length >= 1, "Marketplace snapshot is empty");
const ids = new Set(snapshot.entries.map((entry) => entry.id));
assert(ids.size === snapshot.entries.length, "Marketplace snapshot contains duplicate ids");
assert(snapshot.entries.some((entry) => entry.kind === "channel"), "Marketplace snapshot has no Channel connector");
assert(ids.has("dev.termite.demo-inbox"), "Marketplace snapshot is missing Demo Inbox");
const channels = snapshot.entries.filter((entry) => entry.kind === "channel");
assert(channels.length >= 19, `Marketplace snapshot has only ${channels.length} Channels`);
for (const id of [
  "dev.termite.slack", "dev.termite.imessage", "dev.termite.github-issues",
  "dev.termite.webhook-inbox", "dev.termite.rss-feed", "dev.termite.apple-reminders"
]) {
  assert(ids.has(id), `Marketplace snapshot is missing ${id}`);
}
assert(Array.isArray(snapshot.featured) && snapshot.featured.every((id) => ids.has(id)), "Marketplace featured list references an unknown id");

const scripts = [...referencedAssets].filter((path) => /^assets\/.*\.js$/.test(path));
const styles = [...referencedAssets].filter((path) => /^assets\/.*\.css$/.test(path));
assert(scripts.length === 1, `expected one application script, found ${scripts.length}`);
assert(styles.length === 1, `expected one application stylesheet, found ${styles.length}`);

const bundle = await readFile(resolve(site, scripts[0]), "utf8");
for (const marker of ["Extensions add capabilities", "Choose one of three paths", "The terminal", "Bundled snapshot"]) {
  assert(bundle.includes(marker), `application bundle is missing marker: ${marker}`);
}

const css = await readFile(resolve(site, styles[0]), "utf8");
assert(css.includes("prefers-reduced-motion"), "stylesheet has no reduced-motion mode");
assert(css.includes("focus-visible"), "stylesheet has no visible keyboard focus rules");
assert(/text-transform:\s*lowercase/.test(css), "stylesheet is missing the lowercase editorial voice");
assert(/\.case[^}]*text-transform:\s*none/.test(css), "stylesheet is missing canonical-case opt-outs");
assert(/@media\s*\(max-width:\s*620px\)/.test(css), "stylesheet has no compact mobile layout");

console.log(`verified ${pages.length} pages, ${referencedAssets.size} local assets, ${snapshot.entries.length} Marketplace entries, and ${channels.length} Channels`);
