'use strict';

const fs = require('fs');
const path = require('path');

function slug(value) {
  return String(value)
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '');
}

function environmentPrefix(value) {
  return slug(value).toUpperCase().replace(/-/g, '_');
}

function loadManifest() {
  const candidates = [
    // Installed beside an MCP shim by plugins.sh.
    path.join(__dirname, 'product-identity.json'),
    // Source checkout.
    path.join(
      __dirname, '..', 'Sources', 'ProductIdentity', 'Resources',
      'product-identity.json'),
  ];
  for (const candidate of candidates) {
    try {
      const stat = fs.statSync(candidate);
      if (!stat.isFile() || stat.size > 64 * 1024) continue;
      return JSON.parse(fs.readFileSync(candidate, 'utf8'));
    } catch {}
  }
  throw new Error('product-identity.json is missing');
}

const manifest = loadManifest();
const productSlug = slug(manifest.name);
const legacySlugs = (manifest.legacyNames || [])
  .map(slug)
  .filter((value) => value && value !== productSlug);

function environmentValue(suffix, environment = process.env) {
  const prefixes = [
    environmentPrefix(productSlug),
    'PRODUCT',
    ...legacySlugs.map(environmentPrefix),
  ];
  for (const prefix of prefixes) {
    const value = environment[`${prefix}_${suffix}`];
    if (typeof value === 'string' && value.length > 0) return value;
  }
  return undefined;
}

module.exports = {
  manifest,
  name: manifest.name,
  slug: productSlug,
  // Preserve the exact public casing from the shared manifest. Environment
  // keys still derive independently as uppercase identifiers.
  titleName: manifest.name,
  environmentPrefix: environmentPrefix(productSlug),
  legacySlugs,
  configDirectoryName: productSlug,
  mcpServerName(component) { return `${productSlug}-${component}`; },
  environmentValue,
};
