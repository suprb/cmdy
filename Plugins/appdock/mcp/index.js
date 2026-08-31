#!/usr/bin/env node

/**
 * AppDock MCP stdio server for the AppDock extension.
 *
 * Bridges the plugin's HTTP API (POST /execute {tool, arguments}) to MCP so
 * any agent — Claude Code, codex, pi — can drive the native app docked in
 * cmdy: launch it, relaunch after an edit, read its Accessibility tree,
 * click/type into it, screenshot it, and read its captured logs. The dev
 * loop for an agent building a Mac/iOS-Simulator app, beside the conversation.
 *
 * plugins.sh installs and registers the identity-derived server name.
 */

const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');
const readline = require('readline');

function loadProductIdentity() {
  const candidates = [
    path.join(__dirname, 'product-identity.js'),
    path.join(__dirname, '..', '..', '..', 'Identity', 'Node', 'product-identity.js'),
  ];
  for (const candidate of candidates) {
    try { return require(candidate); } catch {}
  }
  throw new Error('Product identity module is missing');
}

const PRODUCT = loadProductIdentity();
const MCP_SERVER_NAME = PRODUCT.mcpServerName('appdock');
const CONFIG_ROOT = path.join(
  os.homedir(), '.config', PRODUCT.configDirectoryName);
const DISCOVERY_FILE = path.join(CONFIG_ROOT, 'appdock-api.json');
const DEFAULT_PORT = 4690;
const MAX_RESPONSE_BYTES = 32 * 1024 * 1024;

let endpoint = null;

function normalizeEndpoint(port, token) {
  const numericPort = Number(port);
  return {
    port: Number.isInteger(numericPort) && numericPort >= 1 && numericPort <= 65535
      ? numericPort : DEFAULT_PORT,
    token: typeof token === 'string' && token.length > 0 && token.length <= 4096
      ? token : null,
  };
}

function readJsonFile(file) {
  const stat = fs.statSync(file);
  if (!stat.isFile() || stat.size > 64 * 1024) throw new Error('Invalid discovery file');
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function resolveEndpoint() {
  const environmentPort = PRODUCT.environmentValue('APPDOCK_PORT');
  if (environmentPort) {
    return normalizeEndpoint(
      environmentPort,
      PRODUCT.environmentValue('APPDOCK_TOKEN'));
  }
  try {
    const j = readJsonFile(DISCOVERY_FILE);
    if (j.port) return normalizeEndpoint(j.port, j.token);
  } catch {}
  return { port: DEFAULT_PORT, token: null };
}

function collectJsonResponse(res, resolve, reject, maxBytes = MAX_RESPONSE_BYTES) {
  const chunks = [];
  let bytes = 0;
  let settled = false;
  const fail = (error) => {
    if (settled) return;
    settled = true;
    reject(error);
  };
  res.on('data', (chunk) => {
    if (settled) return;
    bytes += chunk.length;
    if (bytes > maxBytes) {
      res.destroy();
      fail(new Error(`Response exceeds ${Math.floor(maxBytes / (1024 * 1024))} MB`));
      return;
    }
    chunks.push(chunk);
  });
  res.on('error', fail);
  res.on('end', () => {
    if (settled) return;
    settled = true;
    const text = Buffer.concat(chunks).toString('utf8');
    if (res.statusCode === 401 || res.statusCode === 403) {
      reject(new Error(`Authentication failed (HTTP ${res.statusCode})`));
      return;
    }
    if ((res.statusCode || 500) >= 400) {
      reject(new Error(`HTTP ${res.statusCode}: ${text.slice(0, 1000)}`));
      return;
    }
    try { resolve(JSON.parse(text)); } catch { resolve({ error: text }); }
  });
}

const TOOLS = [
  // Lifecycle
  { name: 'launch', description: `Launch an app (a .app bundle path, or a bare executable) and dock its window into ${PRODUCT.titleName}. Captures stdout/stderr for \`logs\`. This is how you start the app you are building.`, inputSchema: { type: 'object', properties: { bundle: { type: 'string', description: 'Path to a .app bundle' }, command: { type: 'string', description: 'Path to an executable (alternative to bundle)' }, args: { type: 'array', items: { type: 'string' }, description: 'Arguments for command' } } } },
  { name: 'dock', description: `Dock an ALREADY-RUNNING app into ${PRODUCT.titleName} by pid, bundle id, or name`, inputSchema: { type: 'object', properties: { pid: { type: 'number' }, bundle: { type: 'string', description: 'Bundle identifier' }, name: { type: 'string', description: 'App display name, e.g. Calculator' } } } },
  { name: 'relaunch', description: 'Quit and relaunch the docked app — the core of the edit→run loop: after you change the source and rebuild, relaunch to see it live', inputSchema: { type: 'object', properties: {} } },
  { name: 'undock', description: 'Release the docked app, restoring its previous window position', inputSchema: { type: 'object', properties: {} } },
  { name: 'info', description: 'What is docked right now, and whether the Accessibility permission is granted', inputSchema: { type: 'object', properties: {} } },
  { name: 'logs', description: 'The docked app\'s captured stdout/stderr (only for apps launched via appdock) — read crashes and prints here', inputSchema: { type: 'object', properties: { tail: { type: 'number', description: 'Max characters from the end (default 4000)' } } } },

  // Inspect
  { name: 'ax_tree', description: 'The docked app\'s Accessibility tree — its UI as a list of nodes (role, title, value, path, frame). `path` is an index path used by ax_click/ax_type. This is the app\'s DOM.', inputSchema: { type: 'object', properties: { depth: { type: 'number', description: 'Max depth (default 12)' }, all: { type: 'boolean', description: 'Include non-interactive nodes too (default false)' } } } },
  { name: 'ax_find', description: 'Find elements in the docked app by text/role substring — returns matching nodes with their paths', inputSchema: { type: 'object', properties: { query: { type: 'string' } }, required: ['query'] } },
  { name: 'screenshot', description: 'Screenshot the docked app\'s window (needs the Screen Recording permission the first time)', inputSchema: { type: 'object', properties: {} } },

  // Drive
  { name: 'ax_click', description: 'Click an element by its ax_tree path (AXPress, or a synthetic click at its center)', inputSchema: { type: 'object', properties: { path: { type: 'string', description: 'Index path from ax_tree' } }, required: ['path'] } },
  { name: 'ax_type', description: 'Type text into an element by its ax_tree path', inputSchema: { type: 'object', properties: { path: { type: 'string' }, text: { type: 'string' } }, required: ['path', 'text'] } },
  { name: 'ax_focus', description: 'Focus an element by its ax_tree path', inputSchema: { type: 'object', properties: { path: { type: 'string' } }, required: ['path'] } },
  { name: 'key', description: 'Press a key in the docked app (return, tab, escape, arrows, space, delete) with optional modifiers', inputSchema: { type: 'object', properties: { key: { type: 'string' }, modifiers: { type: 'array', items: { type: 'string' }, description: 'cmd, shift, alt, ctrl' } }, required: ['key'] } },
];

async function callHttpApi(tool, args, isRetry = false) {
  if (!endpoint) endpoint = resolveEndpoint();
  const attempt = () => new Promise((resolve, reject) => {
    const postData = JSON.stringify({ tool, arguments: args });
    const headers = { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(postData) };
    if (endpoint.token) headers['Authorization'] = `Bearer ${endpoint.token}`;
    const req = http.request({ hostname: '127.0.0.1', port: endpoint.port, path: '/execute', method: 'POST', headers },
      (res) => collectJsonResponse(res, resolve, reject));
    req.on('error', reject);
    req.setTimeout(120000, () => { req.destroy(); reject(new Error('timeout')); });
    req.write(postData); req.end();
  });
  try { return await attempt(); }
  catch (e) {
    if (!isRetry) { endpoint = resolveEndpoint(); return callHttpApi(tool, args, true); }
    throw new Error(`${MCP_SERVER_NAME} not reachable on port ${endpoint.port}: ${e.message} — is the AppDock plugin enabled?`);
  }
}

function probeHealth() {
  endpoint = resolveEndpoint();
  return new Promise((resolve) => {
    const req = http.request({ hostname: '127.0.0.1', port: endpoint.port, path: '/health', method: 'GET' },
      (res) => collectJsonResponse(
        res,
        (json) => resolve(
          json?.status === 'ok' && json?.app === `${PRODUCT.slug}-appdock`
            && json?.api === 'appdock-v1' ? json : null),
        () => resolve(null),
        64 * 1024));
    req.on('error', () => resolve(null));
    req.setTimeout(500, () => { req.destroy(); resolve(null); });
    req.end();
  });
}

let healthWatcherStarted = false;
let lastHealthyState = false;
function startHealthWatcher() {
  if (healthWatcherStarted) return;
  healthWatcherStarted = true;
  const timer = setInterval(async () => {
    const healthy = !!(await probeHealth());
    if (healthy !== lastHealthyState) {
      lastHealthyState = healthy;
      console.log(JSON.stringify({
        jsonrpc: '2.0',
        method: 'notifications/tools/list_changed',
      }));
    }
  }, 1500);
  timer.unref();
}

function handleInitialize(id) {
  startHealthWatcher();
  return { jsonrpc: '2.0', id, result: { protocolVersion: '2024-11-05',
    capabilities: { tools: { listChanged: true } },
    serverInfo: { name: MCP_SERVER_NAME, version: '1.0.0' } } };
}

async function handleListTools(id) {
  const health = await probeHealth();
  return { jsonrpc: '2.0', id, result: { tools: health ? TOOLS : [] } };
}

const ACTION_TOOLS = new Set(['launch', 'relaunch', 'ax_click', 'ax_type', 'key']);

async function handleCallTool(id, params) {
  const { name, arguments: args = {} } = params || {};
  if (typeof name !== 'string' || !TOOLS.some((tool) => tool.name === name)) {
    return { jsonrpc: '2.0', id, error: { code: -32602, message: 'Invalid tool name' } };
  }
  try {
    const response = await callHttpApi(name, args || {});
    if (response.error) {
      return { jsonrpc: '2.0', id, result: { content: [{ type: 'text', text: `Error: ${response.error}` }] } };
    }
    const result = response.result;
    let content;
    if (name === 'screenshot' && result?.image) {
      content = [{ type: 'image', data: result.image, mimeType: `image/${result.format || 'jpeg'}` }];
    } else if ((name === 'ax_tree' || name === 'ax_find') && result?.nodes) {
      const lines = result.nodes.map(n =>
        `[${n.path}] ${n.role}${n.title ? ` "${n.title}"` : ''}${n.value ? ` = ${JSON.stringify(n.value)}` : ''}${n.enabled === false ? ' (disabled)' : ''}`);
      content = [{ type: 'text', text: `${result.count} nodes:\n${lines.join('\n')}` }];
    } else if (name === 'logs') {
      content = [{ type: 'text', text: result?.logs || '(no output captured)' }];
    } else {
      content = [{ type: 'text', text: JSON.stringify(result, null, 2) }];
    }
    // After an action that changes the UI, append a screenshot for grounding.
    if (ACTION_TOOLS.has(name) && result?.docked !== false) {
      try {
        const shot = await callHttpApi('screenshot', {});
        if (shot?.result?.image) content.push({ type: 'image', data: shot.result.image, mimeType: `image/${shot.result.format || 'jpeg'}` });
      } catch {}
    }
    return { jsonrpc: '2.0', id, result: { content } };
  } catch (error) {
    return { jsonrpc: '2.0', id, error: { code: -32000, message: error.message } };
  }
}

async function handleMessage(message) {
  const { method, id, params } = message;
  switch (method) {
    case 'initialize': return handleInitialize(id);
    case 'initialized': case 'notifications/initialized': case 'notifications/cancelled': return null;
    case 'tools/list': return handleListTools(id);
    case 'tools/call': return await handleCallTool(id, params);
    default: return id == null ? null : { jsonrpc: '2.0', id, error: { code: -32601, message: `Method not found: ${method}` } };
  }
}

function startServer() {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout, terminal: false });
  let inFlight = 0, closed = false;
  const maybeExit = () => { if (closed && inFlight === 0) process.exit(0); };
  rl.on('line', async (line) => {
    inFlight++;
    try {
      const message = JSON.parse(line);
      const response = await handleMessage(message);
      if (response) console.log(JSON.stringify(response));
    } catch {
      console.log(JSON.stringify({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Parse error' } }));
    } finally { inFlight--; maybeExit(); }
  });
  rl.on('close', () => { closed = true; maybeExit(); });
}

startServer();
