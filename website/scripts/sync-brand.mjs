import { copyFile, mkdir, readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "../..");
const identity = JSON.parse(await readFile(
  resolve(root, "Identity/Sources/ProductIdentity/Resources/product-identity.json"),
  "utf8"
));

if (typeof identity.name !== "string" || identity.name.trim() === "") {
  throw new Error("product identity has no public name");
}

const assets = [
  ["Brand/Assets/app-icon.png", "website/public/app-icon.png"],
  ["Brand/Assets/cmdy-wordmark.svg", "website/public/cmdy-wordmark.svg"],
  ["Brand/Assets/AlphaLyrae-Medium.woff2", "website/public/fonts/AlphaLyrae-Medium.woff2"],
  ["Brand/Assets/AlphaLyrae-LICENSE.md", "website/public/fonts/AlphaLyrae-LICENSE.md"],
  ["Brand/Assets/OFL-1.1.txt", "website/public/fonts/OFL-1.1.txt"],
  ["Kit/Sources/CmdyKit/Fonts/GeistMono-LICENSE.txt", "website/public/fonts/GeistMono-LICENSE.txt"],
  ["website/THIRD_PARTY_NOTICES.md", "website/public/THIRD_PARTY_NOTICES.md"]
];

for (const [source, destination] of assets) {
  const output = resolve(root, destination);
  await mkdir(dirname(output), { recursive: true });
  await copyFile(resolve(root, source), output);
}
