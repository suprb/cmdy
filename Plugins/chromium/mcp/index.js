#!/usr/bin/env node

/**
 * Browser MCP stdio server for the Chromium extension.
 *
 * Bridges the plugin-local HTTP API (POST /execute {tool, arguments}) to the
 * MCP stdio protocol so any agent — Claude Code, codex, pi — can drive the
 * Chromium sidecar natively. Adapted from Braincell's mcp/index.js (same wire
 * shape); the endpoint is discovered from the product config directory,
 * which the plugin writes on launch ({port, token}).
 *
 * plugins.sh installs and registers the identity-derived server name.
 */

const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');
const readline = require('readline');
const { pathToFileURL } = require('url');
const { execFileSync } = require('child_process');

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
const APP_NAME = `${PRODUCT.name} chromium plugin`;
const MCP_SERVER_NAME = PRODUCT.mcpServerName('browser');
const MCP_VERSION = '1.0.0';

const CONFIG_ROOT = path.join(
  os.homedir(), '.config', PRODUCT.configDirectoryName);
const DISCOVERY_FILE = path.join(CONFIG_ROOT, 'browser-api.json');
const HOST_DISCOVERY_FILE = path.join(CONFIG_ROOT, 'extension-api.json');
const DEFAULT_PORT = 4680;
const MAX_RESPONSE_BYTES = 32 * 1024 * 1024;

// Endpoint resolution: env override (gates, multi-instance) → discovery file
// (the normal path) → bare default. Re-resolved whenever a request fails, so
// a cmdy restart with a new port heals on the next call.
let endpoint = null; // {port, token}

function currentDirectory() {
  try { return process.cwd(); } catch { return os.homedir(); }
}

function normalizeEndpoint(port, token, fallbackPort) {
  const numericPort = Number(port);
  return {
    port: Number.isInteger(numericPort) && numericPort >= 1 && numericPort <= 65535
      ? numericPort : fallbackPort,
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
  const environmentPort = PRODUCT.environmentValue('BROWSER_PORT');
  if (environmentPort) {
    return normalizeEndpoint(
      environmentPort,
      PRODUCT.environmentValue('BROWSER_TOKEN'),
      DEFAULT_PORT);
  }
  try {
    const j = readJsonFile(DISCOVERY_FILE);
    if (j.port) return normalizeEndpoint(j.port, j.token, DEFAULT_PORT);
  } catch {}
  return { port: DEFAULT_PORT, token: null };
}

// Resolve the Cmdy window that owns this MCP process. Browser can keep one
// sidecar per Cmdy window, so routing only by the plugin's global endpoint
// otherwise drives whichever Browser happened to be active most recently.
let targetContextCache = { value: null, expires: 0 };

function processAncestors() {
  const ancestors = [];
  let pid = process.ppid;
  for (let depth = 0; depth < 16 && Number.isFinite(pid) && pid > 1; depth++) {
    ancestors.push(pid);
    try {
      const out = execFileSync('/bin/ps', ['-o', 'ppid=', '-p', String(pid)], {
        encoding: 'utf8',
        timeout: 1000,
      }).trim();
      const parent = parseInt(out, 10);
      if (!Number.isFinite(parent) || parent <= 1 || parent === pid) break;
      pid = parent;
    } catch {
      break;
    }
  }
  return ancestors;
}

function cmdyConnection() {
  try {
    const j = readJsonFile(HOST_DISCOVERY_FILE);
    const connection = normalizeEndpoint(j.port, j.token, 0);
    if (connection.port > 0 && connection.token) return connection;
  } catch {}
  return null;
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

function cmdyPanes(connection) {
  return new Promise((resolve) => {
    const req = http.request({
      hostname: '127.0.0.1',
      port: connection.port,
      path: '/v1/panes',
      method: 'GET',
      headers: { Authorization: `Bearer ${connection.token}` },
    }, (res) => {
      collectJsonResponse(res, (json) => resolve(json?.panes || []), () => resolve([]), 1024 * 1024);
    });
    req.on('error', () => resolve([]));
    req.setTimeout(1000, () => { req.destroy(); resolve([]); });
    req.end();
  });
}

async function resolveTargetContext() {
  const explicit = parseInt(PRODUCT.environmentValue('BROWSER_WINDOW') || '', 10);
  if (Number.isFinite(explicit) && explicit > 0 && explicit <= 0xFFFFFFFF) {
    return {
      window: explicit,
      cwd: PRODUCT.environmentValue('BROWSER_CWD') || currentDirectory(),
    };
  }

  const now = Date.now();
  if (now < targetContextCache.expires) return targetContextCache.value;
  const connection = cmdyConnection();
  if (!connection) return { window: null, cwd: currentDirectory() };
  const panes = await cmdyPanes(connection);
  const ancestors = processAncestors();
  const rank = new Map(ancestors.map((pid, index) => [pid, index]));
  const owning = panes
    .filter((pane) => rank.has(Number(pane.pid)) && Number(pane.windowNumber) > 0)
    .sort((a, b) => rank.get(Number(a.pid)) - rank.get(Number(b.pid)))[0];
  const focused = panes.find((pane) => pane.focused && Number(pane.windowNumber) > 0);
  const pane = owning || focused || null;
  const value = {
    window: Number(pane?.windowNumber || 0) || null,
    cwd: pane?.cwd || currentDirectory(),
  };
  targetContextCache = { value, expires: now + 1000 };
  return value;
}

function routedArguments(tool, args, cwd) {
  if (tool !== 'navigate' || typeof args?.url !== 'string') return args;
  const raw = args.url.trim();
  if (!raw) return args;
  if (/^[a-z][a-z0-9+.-]*:/i.test(raw)) return { ...args, url: raw };
  if (/^(?:localhost|127\.0\.0\.1|\[::1\])(?::\d+)?(?:\/|$)/i.test(raw)) {
    return { ...args, url: `http://${raw}` };
  }
  if (/^www\./i.test(raw)) return { ...args, url: `https://${raw}` };

  const expanded = raw === '~' || raw.startsWith('~/')
    ? path.join(os.homedir(), raw.slice(2))
    : raw;
  const localPath = path.resolve(cwd || currentDirectory(), expanded);
  if (fs.existsSync(localPath)) {
    return { ...args, url: pathToFileURL(localPath).href };
  }
  return args;
}

// Tool definitions matching the plugin's HTTP API.
// Short names so they become mcp__cmdy-browser__navigate, __click, etc.
const TOOLS = [
  // Navigation
  { name: 'navigate', description: `Open a URL or local file in the ${PRODUCT.titleName} Browser visibly attached to this terminal. Prefer this over a generic in-app browser or the macOS \`open\` command when the user asks to open, preview, or inspect a page in ${PRODUCT.titleName}. Relative file paths resolve from this terminal pane’s working directory.`, inputSchema: { type: 'object', properties: { url: { type: 'string', description: 'URL, absolute file path, or pane-relative file path such as index.html' } }, required: ['url'] } },
  { name: 'reload', description: 'Reload the current page', inputSchema: { type: 'object', properties: {} } },
  { name: 'back', description: 'Go back in browser history', inputSchema: { type: 'object', properties: {} } },
  { name: 'forward', description: 'Go forward in browser history', inputSchema: { type: 'object', properties: {} } },
  { name: 'get_url', description: 'Get the current URL', inputSchema: { type: 'object', properties: {} } },
  { name: 'get_title', description: 'Get the page title', inputSchema: { type: 'object', properties: {} } },

  // Interactions
  { name: 'click', description: 'Click an element by CSS selector', inputSchema: { type: 'object', properties: { selector: { type: 'string', description: 'CSS selector' } }, required: ['selector'] } },
  { name: 'double_click', description: 'Double-click an element', inputSchema: { type: 'object', properties: { selector: { type: 'string', description: 'CSS selector' } }, required: ['selector'] } },
  { name: 'right_click', description: 'Right-click an element (context menu)', inputSchema: { type: 'object', properties: { selector: { type: 'string', description: 'CSS selector' } }, required: ['selector'] } },
  { name: 'hover', description: 'Hover over an element', inputSchema: { type: 'object', properties: { selector: { type: 'string', description: 'CSS selector' } }, required: ['selector'] } },
  { name: 'focus', description: 'Focus an element', inputSchema: { type: 'object', properties: { selector: { type: 'string', description: 'CSS selector' } }, required: ['selector'] } },

  // Input
  { name: 'type', description: 'Type text into an input element', inputSchema: { type: 'object', properties: { selector: { type: 'string', description: 'CSS selector' }, text: { type: 'string', description: 'Text to type' }, clear: { type: 'boolean', description: 'Clear existing content first (default true)' } }, required: ['selector', 'text'] } },
  { name: 'press_key', description: 'Press a keyboard key', inputSchema: { type: 'object', properties: { key: { type: 'string', description: 'Key to press (e.g., Enter, Tab, Escape)' }, modifiers: { type: 'array', items: { type: 'string' }, description: 'Modifier keys: ctrl, shift, alt, meta' } }, required: ['key'] } },

  // Forms
  { name: 'select_option', description: 'Select a dropdown option', inputSchema: { type: 'object', properties: { selector: { type: 'string', description: 'CSS selector for select element' }, value: { type: 'string', description: 'Option value' } }, required: ['selector', 'value'] } },
  { name: 'set_checkbox', description: 'Check or uncheck a checkbox', inputSchema: { type: 'object', properties: { selector: { type: 'string', description: 'CSS selector' }, checked: { type: 'boolean', description: 'Whether to check or uncheck' } }, required: ['selector', 'checked'] } },
  { name: 'get_forms', description: 'Get all forms on the page with their fields', inputSchema: { type: 'object', properties: {} } },
  { name: 'fill_form', description: 'Fill multiple form fields at once', inputSchema: { type: 'object', properties: { fields: { type: 'array', items: { type: 'object', properties: { selector: { type: 'string' }, value: { type: 'string' } }, required: ['selector', 'value'] }, description: 'Array of {selector, value} pairs' } }, required: ['fields'] } },
  { name: 'submit_form', description: 'Submit a form', inputSchema: { type: 'object', properties: { selector: { type: 'string', description: 'CSS selector for form (default: form)' } } } },

  // Scroll & Drag
  { name: 'scroll', description: 'Scroll the page or to an element', inputSchema: { type: 'object', properties: { selector: { type: 'string', description: 'CSS selector to scroll into view' }, direction: { type: 'string', enum: ['up', 'down'], description: 'Scroll direction' }, amount: { type: 'number', description: 'Scroll amount in pixels' } } } },
  { name: 'drag_drop', description: 'Drag an element to another', inputSchema: { type: 'object', properties: { source: { type: 'string', description: 'CSS selector for drag source' }, target: { type: 'string', description: 'CSS selector for drop target' } }, required: ['source', 'target'] } },

  // Reading
  { name: 'get_content', description: 'Get text or HTML content of page or element', inputSchema: { type: 'object', properties: { selector: { type: 'string', description: 'CSS selector (default: body)' }, type: { type: 'string', enum: ['text', 'html'], description: 'Content type' } } } },
  { name: 'get_element', description: 'Get information about an element', inputSchema: { type: 'object', properties: { selector: { type: 'string', description: 'CSS selector' } }, required: ['selector'] } },
  { name: 'list_interactive', description: 'List all interactive elements (buttons, links, inputs)', inputSchema: { type: 'object', properties: { limit: { type: 'number', description: 'Max elements to return' } } } },
  { name: 'find', description: 'Find elements using natural language description (e.g., "search bar", "login button")', inputSchema: { type: 'object', properties: { query: { type: 'string', description: 'Natural language description of what to find' }, limit: { type: 'number', description: 'Max elements to return (default: 10)' } }, required: ['query'] } },
  { name: 'wait_for', description: 'Wait for an element to appear', inputSchema: { type: 'object', properties: { selector: { type: 'string', description: 'CSS selector' }, timeout: { type: 'number', description: 'Timeout in ms (default: 5000)' } }, required: ['selector'] } },
  { name: 'screenshot', description: 'Take a screenshot of the browser sidecar (needs the Screen Recording permission the first time)', inputSchema: { type: 'object', properties: {} } },
  { name: 'execute_js', description: 'Execute JavaScript in the page and return its JSON-serializable result', inputSchema: { type: 'object', properties: { code: { type: 'string', description: 'JavaScript expression to execute' } }, required: ['code'] } },

  // Semantic UI feedback
  { name: 'begin_feedback', description: `Open ${PRODUCT.titleName}'s live element picker so the user can point at a page element and send a structured note to the paired agent`, inputSchema: { type: 'object', properties: {} } },
  { name: 'get_feedback', description: 'List structured UI feedback captured from Browser or Sim Mirror', inputSchema: { type: 'object', properties: { status: { type: 'string', enum: ['open', 'resolved'] }, id: { type: 'string' } } } },
  { name: 'resolve_feedback', description: 'Mark a UI feedback item resolved', inputSchema: { type: 'object', properties: { id: { type: 'string' }, resolution: { type: 'string' } }, required: ['id'] } },
  { name: 'clear_feedback', description: 'Clear UI feedback records', inputSchema: { type: 'object', properties: { resolvedOnly: { type: 'boolean', description: 'Only clear resolved records' } } } },

  // Console
  { name: 'get_console', description: 'Get browser console messages (the CEF bridge does not expose severity — filter with pattern instead)', inputSchema: { type: 'object', properties: { limit: { type: 'number', description: 'Max messages (default: 50)' }, pattern: { type: 'string', description: 'Regex pattern to filter' }, clear: { type: 'boolean', description: 'Clear after reading' } } } },
  { name: 'clear_console', description: 'Clear console messages', inputSchema: { type: 'object', properties: {} } },

  // Response verbosity
  { name: 'set_thoroughness', description: 'Set how thorough browser tool responses are. 1=minimal (text-mode screenshots), 2=balanced (screenshot after mutations), 3=thorough (screenshot + page text after every action).', inputSchema: { type: 'object', properties: { level: { type: 'number', description: '1 (minimal), 2 (balanced), or 3 (thorough)' } }, required: ['level'] } },
  { name: 'get_thoroughness', description: 'Get the current thoroughness level', inputSchema: { type: 'object', properties: {} } },
];

// Call the plugin's HTTP API. On connection failure, re-resolve the endpoint
// (cmdy may have restarted on a new port) and retry once.
async function callHttpApi(tool, args, isRetry = false, targetContext = undefined) {
  if (!endpoint) endpoint = resolveEndpoint();
  if (targetContext === undefined) targetContext = await resolveTargetContext();

  const attempt = () => new Promise((resolve, reject) => {
    const body = {
      tool,
      arguments: routedArguments(tool, args, targetContext?.cwd),
    };
    if (targetContext?.window) body.window = targetContext.window;
    const postData = JSON.stringify(body);
    const headers = {
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(postData),
    };
    if (endpoint.token) headers['Authorization'] = `Bearer ${endpoint.token}`;

    const req = http.request(
      { hostname: '127.0.0.1', port: endpoint.port, path: '/execute', method: 'POST', headers },
      (res) => {
        collectJsonResponse(res, resolve, reject);
      }
    );
    req.on('error', (e) => reject(e));
    req.setTimeout(120000, () => {
      req.destroy();
      reject(new Error('Request timeout'));
    });
    req.write(postData);
    req.end();
  });

  try {
    return await attempt();
  } catch (e) {
    if (!isRetry) {
      endpoint = resolveEndpoint();
      targetContextCache.expires = 0;
      return callHttpApi(tool, args, true, targetContext);
    }
    throw new Error(`${APP_NAME} not reachable on port ${endpoint.port}: ${e.message} — is the Chromium plugin enabled in ${PRODUCT.name}?`);
  }
}

// Quick HTTP probe used by tools/list to decide whether to advertise.
function probeHealth() {
  endpoint = resolveEndpoint();
  return new Promise((resolve) => {
    const req = http.request(
      { hostname: '127.0.0.1', port: endpoint.port, path: '/health', method: 'GET' },
      (res) => {
        collectJsonResponse(
          res,
          (json) => resolve(
            json?.status === 'ok' && json?.app === `${PRODUCT.slug}-chromium`
              && json?.api === 'browser-v1' ? json : null),
          () => resolve(null),
          64 * 1024);
      }
    );
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

// MCP protocol handlers
function handleInitialize(id) {
  startHealthWatcher();
  return {
    jsonrpc: '2.0',
    id,
    result: {
      protocolVersion: '2024-11-05',
      capabilities: { tools: { listChanged: true } },
      serverInfo: { name: MCP_SERVER_NAME, version: MCP_VERSION },
      instructions: `Use ${MCP_SERVER_NAME} for the Chromium sidecar attached to the current ${PRODUCT.titleName} terminal. It supports URLs and local paths such as index.html; do not fall back to a generic browser backend or the macOS open command when this server is available.`,
    },
  };
}

async function handleListTools(id) {
  // Advertise nothing when the plugin isn't running — the agent sees an
  // empty server instead of 30 tools that all fail.
  const health = await probeHealth();
  if (!health) {
    return { jsonrpc: '2.0', id, result: { tools: [] } };
  }
  return { jsonrpc: '2.0', id, result: { tools: TOOLS } };
}

// Tools that mutate the page — candidates for thoroughness enrichment.
const ACTION_TOOLS = new Set([
  'click', 'double_click', 'right_click', 'type', 'navigate', 'reload', 'back', 'forward',
  'press_key', 'hover', 'scroll', 'drag_drop', 'select_option', 'set_checkbox',
  'fill_form', 'submit_form', 'focus',
]);

async function handleCallTool(id, params) {
  const { name, arguments: args = {} } = params || {};
  if (typeof name !== 'string' || !TOOLS.some((tool) => tool.name === name)) {
    return { jsonrpc: '2.0', id, error: { code: -32602, message: 'Invalid tool name' } };
  }

  try {
    const response = await callHttpApi(name, args || {});
    const result = response.result;

    if (response.error) {
      return { jsonrpc: '2.0', id, result: { content: [{ type: 'text', text: `Error: ${response.error}` }] } };
    }

    // Format the inner result for display
    let content;
    if (name === 'screenshot' && result?.image) {
      // Proper MCP image content (NOT text) so the payload doesn't hit the
      // tool-result text cap.
      content = [{ type: 'image', data: result.image, mimeType: `image/${result.format || 'jpeg'}` }];
    } else if (name === 'screenshot' && result?.mode === 'text') {
      content = [{ type: 'text', text: result.content || '' }];
    } else if (name === 'get_console' && result?.messages) {
      const formatted = result.messages.map((m) => `[${m.type}] ${m.content}`).join('\n');
      content = [{ type: 'text', text: `Console messages (${result.count}):\n${formatted}` }];
    } else if (name === 'get_feedback' && result?.feedback) {
      const formatted = result.feedback.map((item) => {
        const ctx = item.context || {};
        return `[${item.status || 'open'}] ${item.id}\n${item.comment}\n${ctx.selector || ctx.elementPath || ctx.label || ctx.element || ''}`;
      }).join('\n\n');
      content = [{ type: 'text', text: `UI feedback (${result.count}):\n${formatted || 'None'}` }];
    } else if (name === 'list_interactive' && result?.elements) {
      const formatted = result.elements
        .map((e) => `[${e.index}] <${e.tag}> ${e.selector} "${(e.text || '').substring(0, 40)}"`)
        .join('\n');
      content = [{ type: 'text', text: `Interactive elements (${result.count}):\n${formatted}` }];
    } else if (name === 'find' && result?.elements) {
      const formatted = result.elements
        .map((e, i) => `[${i + 1}] <${e.tag}> score:${e.score} "${(e.text || '').substring(0, 50)}" → ${e.selector}\n    Match: ${e.matchReason}`)
        .join('\n');
      content = [{ type: 'text', text: `Found ${result.count} elements for "${result.query}":\n${formatted}` }];
    } else {
      content = [{ type: 'text', text: JSON.stringify(result, null, 2) }];
    }

    // Thoroughness enrichment: auto-append a screenshot (level >= 2) and page
    // text (level 3) after page-mutating actions.
    if (ACTION_TOOLS.has(name) && !response.error) {
      try {
        const th = await callHttpApi('get_thoroughness', {});
        const level = th?.result?.thoroughness || 2;

        if (level >= 2) {
          const shot = await callHttpApi('screenshot', {});
          if (shot?.result?.image) {
            content.push({ type: 'image', data: shot.result.image, mimeType: `image/${shot.result.format || 'jpeg'}` });
          }
        }
        if (level >= 3) {
          const text = await callHttpApi('get_content', { type: 'text' });
          if (text?.result?.content) {
            const truncated = text.result.content.substring(0, 3000);
            content.push({ type: 'text', text: `── Page text (${truncated.length} chars) ──\n${truncated}` });
          }
        }
      } catch {
        // Enrichment failures are non-fatal
      }
    }

    return { jsonrpc: '2.0', id, result: { content } };
  } catch (error) {
    return { jsonrpc: '2.0', id, error: { code: -32000, message: error.message } };
  }
}

// Main message handler
async function handleMessage(message) {
  const { method, id, params } = message;

  switch (method) {
    case 'initialize':
      return handleInitialize(id);
    case 'initialized':
    case 'notifications/initialized':
    case 'notifications/cancelled':
      return null; // Notifications — no response
    case 'tools/list':
      return handleListTools(id);
    case 'tools/call':
      return await handleCallTool(id, params);
    default:
      if (id == null) return null; // Ignore unknown notifications
      return { jsonrpc: '2.0', id, error: { code: -32601, message: `Method not found: ${method}` } };
  }
}

// Start stdio server. Exit when stdin closes — but only after in-flight
// requests drain, so a client (or a piped test) that writes a batch and
// closes still gets every response.
function startServer() {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout, terminal: false });

  let inFlight = 0;
  let closed = false;
  const maybeExit = () => { if (closed && inFlight === 0) process.exit(0); };

  rl.on('line', async (line) => {
    inFlight++;
    try {
      const message = JSON.parse(line);
      const response = await handleMessage(message);
      if (response) console.log(JSON.stringify(response));
    } catch {
      console.log(JSON.stringify({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Parse error' } }));
    } finally {
      inFlight--;
      maybeExit();
    }
  });

  rl.on('close', () => { closed = true; maybeExit(); });
}

startServer();
