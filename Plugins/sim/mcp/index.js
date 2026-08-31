#!/usr/bin/env node

/**
 * Simulator MCP stdio server for the Sim extension.
 *
 * The iOS Simulator dev loop for an agent building a Swift app, beside the
 * conversation: build + install + launch (xcodebuild + xcrun simctl),
 * screenshot the running app, read its logs, tap it, open deep links. When
 * the project is Injection-ready (krzysztofzablocki/Inject + InjectionIII),
 * small edits HOT-RELOAD into the running app — the agent just edits a file
 * and re-screenshots; no rebuild.
 *
 * plugins.sh installs and registers the identity-derived server name.
 */

const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');
const readline = require('readline');
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
const MCP_SERVER_NAME = PRODUCT.mcpServerName('sim');
const CONFIG_ROOT = path.join(
  os.homedir(), '.config', PRODUCT.configDirectoryName);
const DISCOVERY_FILE = path.join(CONFIG_ROOT, 'sim-api.json');
const HOST_DISCOVERY_FILE = path.join(CONFIG_ROOT, 'extension-api.json');
const DEFAULT_PORT = 4700;
const MAX_RESPONSE_BYTES = 32 * 1024 * 1024;

let endpoint = null;
function currentDirectory() {
  try { return process.cwd(); } catch { return os.homedir(); }
}

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
  const environmentPort = PRODUCT.environmentValue('SIM_PORT');
  if (environmentPort) {
    return normalizeEndpoint(
      environmentPort, PRODUCT.environmentValue('SIM_TOKEN'));
  }
  try {
    const j = readJsonFile(DISCOVERY_FILE);
    if (j.port) return normalizeEndpoint(j.port, j.token);
  } catch {}
  return { port: DEFAULT_PORT, token: null };
}

// Resolve this MCP process back to the terminal pane/window that launched its
// agent. Mirrors are window-scoped, just like the built-in Browser sessions;
// routing only through the global Sim API would otherwise target whichever
// Cmdy window happened to be focused most recently.
let targetContextCache = { value: null, expires: 0 };

function processAncestors() {
  const ancestors = [];
  let pid = process.ppid;
  for (let depth = 0;
    depth < 16 && Number.isFinite(pid) && pid > 1;
    depth++) {
    ancestors.push(pid);
    try {
      const out = execFileSync(
        '/bin/ps', ['-o', 'ppid=', '-p', String(pid)],
        { encoding: 'utf8', timeout: 1000 }).trim();
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
    const connection = normalizeEndpoint(j.port, j.token);
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
      collectJsonResponse(
        res,
        (json) => resolve(json?.panes || []),
        () => resolve([]),
        1024 * 1024);
    });
    req.on('error', () => resolve([]));
    req.setTimeout(1000, () => { req.destroy(); resolve([]); });
    req.end();
  });
}

async function resolveTargetContext() {
  const explicit = parseInt(PRODUCT.environmentValue('SIM_WINDOW') || '', 10);
  if (Number.isFinite(explicit) && explicit > 0 && explicit <= 0xFFFFFFFF) {
    return {
      window: explicit,
      cwd: PRODUCT.environmentValue('SIM_CWD') || currentDirectory(),
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
    .filter((pane) => rank.has(Number(pane.pid))
      && Number(pane.windowNumber) > 0)
    .sort((a, b) => rank.get(Number(a.pid)) - rank.get(Number(b.pid)))[0];
  const focused = panes.find(
    (pane) => pane.focused && Number(pane.windowNumber) > 0);
  const pane = owning || focused || null;
  const value = {
    window: Number(pane?.windowNumber || 0) || null,
    cwd: pane?.cwd || currentDirectory(),
  };
  targetContextCache = { value, expires: now + 1000 };
  return value;
}

const TOOLS = [
  { name: 'devices', description: 'List available iOS simulators (name, udid, state, runtime), booted ones first', inputSchema: { type: 'object', properties: {} } },
  { name: 'boot', description: `Boot a simulator and dock its window into ${PRODUCT.titleName}. Default: a booted one, else the first iPhone.`, inputSchema: { type: 'object', properties: { device: { type: 'string', description: 'Device name or udid' } } } },
  { name: 'build', description: 'Build a scheme for the simulator (xcodebuild). Returns the built .app path and bundle id, or the compile errors.', inputSchema: { type: 'object', properties: { project: { type: 'string', description: 'Path to .xcodeproj' }, workspace: { type: 'string', description: 'Path to .xcworkspace (alternative to project)' }, scheme: { type: 'string' }, configuration: { type: 'string', description: 'Debug (default) or Release' } }, required: ['scheme'] } },
  { name: 'run', description: 'The core loop: build → install → launch → dock the Simulator → screenshot. Use this to see the app you are building. After it, if the project is Injection-ready, small edits hot-reload — just re-screenshot instead of running again.', inputSchema: { type: 'object', properties: { project: { type: 'string' }, workspace: { type: 'string' }, scheme: { type: 'string' }, configuration: { type: 'string' } }, required: ['scheme'] } },
  { name: 'screenshot', description: 'Screenshot the booted simulator (no Screen Recording permission needed). Returns width/height — tap x/y use THIS image\'s coordinate space.', inputSchema: { type: 'object', properties: {} } },
  { name: 'logs', description: 'Recent unified-log lines for the running app (its own process)', inputSchema: { type: 'object', properties: { bundleId: { type: 'string', description: 'Defaults to the last app you ran' }, tail: { type: 'number' } } } },
  { name: 'tap', description: 'Tap the simulator at a point USING THE LAST SCREENSHOT\'S coordinates — look at the screenshot, pick the pixel, tap it. (Take a screenshot first. Element-level taps by label need WebDriverAgent; see the plugin README.)', inputSchema: { type: 'object', properties: { x: { type: 'number', description: 'x in the last screenshot image' }, y: { type: 'number', description: 'y in the last screenshot image' } }, required: ['x', 'y'] } },
  { name: 'openurl', description: 'Open a URL / deep link in the simulator', inputSchema: { type: 'object', properties: { url: { type: 'string' } }, required: ['url'] } },
  { name: 'push', description: 'Deliver a push notification (path to an APNs payload JSON)', inputSchema: { type: 'object', properties: { bundleId: { type: 'string' }, payload: { type: 'string' } }, required: ['payload'] } },
  { name: 'terminate', description: 'Terminate the running app', inputSchema: { type: 'object', properties: { bundleId: { type: 'string' } } } },
  { name: 'mirror', description: `Open a window-scoped streamed simulator mirror (serve-sim) in this terminal tab’s built-in Browser. Each ${PRODUCT.titleName} window gets an independent process and port; the native dock remains separate.`, inputSchema: { type: 'object', properties: { device: { type: 'string', description: 'Optional Simulator name or UDID for this window’s mirror' } } } },
  { name: 'mirror_stop', description: 'Stop this terminal window’s serve-sim mirror, or every mirror when all is true', inputSchema: { type: 'object', properties: { all: { type: 'boolean' } } } },
  { name: 'injection_status', description: 'Whether the project is wired for hot reload (krzysztofzablocki/Inject). If ready, edits update the running app without a rebuild.', inputSchema: { type: 'object', properties: { projectDir: { type: 'string' } } } },
  { name: 'begin_feedback', description: `Open ${PRODUCT.titleName}'s live Simulator element picker so the user can point at an interface element and send a structured note to the paired agent`, inputSchema: { type: 'object', properties: {} } },
  { name: 'get_feedback', description: 'List structured Simulator UI feedback', inputSchema: { type: 'object', properties: { status: { type: 'string', enum: ['open', 'resolved'] }, id: { type: 'string' } } } },
  { name: 'resolve_feedback', description: 'Mark a Simulator UI feedback item resolved', inputSchema: { type: 'object', properties: { id: { type: 'string' }, resolution: { type: 'string' } }, required: ['id'] } },
  { name: 'clear_feedback', description: 'Clear Simulator UI feedback records', inputSchema: { type: 'object', properties: { resolvedOnly: { type: 'boolean' } } } },
];

async function callHttpApi(
  tool,
  args,
  isRetry = false,
  targetContext = undefined
) {
  if (!endpoint) endpoint = resolveEndpoint();
  if (targetContext === undefined) {
    targetContext = await resolveTargetContext();
  }
  const attempt = () => new Promise((resolve, reject) => {
    const body = { tool, arguments: args };
    if (targetContext?.window) body.window = targetContext.window;
    const postData = JSON.stringify(body);
    const headers = { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(postData) };
    if (endpoint.token) headers['Authorization'] = `Bearer ${endpoint.token}`;
    const req = http.request({ hostname: '127.0.0.1', port: endpoint.port, path: '/execute', method: 'POST', headers },
      (res) => collectJsonResponse(res, resolve, reject));
    req.on('error', reject);
    req.setTimeout(1_200_000, () => { req.destroy(); reject(new Error('timeout')); });   // builds are slow
    req.write(postData); req.end();
  });
  try { return await attempt(); }
  catch (e) {
    if (!isRetry) {
      endpoint = resolveEndpoint();
      return callHttpApi(tool, args, true, targetContext);
    }
    throw new Error(`${MCP_SERVER_NAME} not reachable on port ${endpoint.port}: ${e.message} — is the Sim plugin enabled?`);
  }
}

function probeHealth() {
  endpoint = resolveEndpoint();
  return new Promise((resolve) => {
    const req = http.request({ hostname: '127.0.0.1', port: endpoint.port, path: '/health', method: 'GET' },
      (res) => collectJsonResponse(
        res,
        (json) => resolve(
          json?.status === 'ok' && json?.app === `${PRODUCT.slug}-sim`
            && json?.api === 'sim-v1' ? json : null),
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

const IMAGE_TOOLS = new Set(['run', 'screenshot', 'tap']);

async function handleCallTool(id, params) {
  const { name, arguments: args = {} } = params || {};
  if (typeof name !== 'string' || !TOOLS.some((tool) => tool.name === name)) {
    return { jsonrpc: '2.0', id, error: { code: -32602, message: 'Invalid tool name' } };
  }
  try {
    const response = await callHttpApi(name, args || {});
    if (response.error) return { jsonrpc: '2.0', id, result: { content: [{ type: 'text', text: `Error: ${response.error}` }] } };
    const result = response.result;
    let content = [];
    if (name === 'devices' && result?.devices) {
      content = [{ type: 'text', text: result.devices.map(d => `${d.state === 'Booted' ? '▶ ' : '  '}${d.name}  [${d.runtime}]  ${d.udid}`).join('\n') }];
    } else if (name === 'injection_status') {
      content = [{ type: 'text', text: `${result.ready ? 'HOT RELOAD READY' : 'no hot reload'} — ${result.reason}` }];
    } else if (name === 'logs') {
      content = [{ type: 'text', text: result?.logs || '(no logs)' }];
    } else if (name === 'get_feedback' && result?.feedback) {
      const formatted = result.feedback.map(item => {
        const ctx = item.context || {};
        return `[${item.status || 'open'}] ${item.id}\n${item.comment}\n${ctx.selector || ctx.elementPath || ctx.label || ctx.element || ''}`;
      }).join('\n\n');
      content = [{ type: 'text', text: `Simulator UI feedback (${result.count}):\n${formatted || 'None'}` }];
    } else {
      // Text summary minus the image blob, then the image if present.
      const { image, ...rest } = result || {};
      content = [{ type: 'text', text: JSON.stringify(rest, null, 2) }];
    }
    if (IMAGE_TOOLS.has(name) && result?.image) {
      content.push({ type: 'image', data: result.image, mimeType: `image/${result.format || 'png'}` });
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
    try { const m = JSON.parse(line); const r = await handleMessage(m); if (r) console.log(JSON.stringify(r)); }
    catch { console.log(JSON.stringify({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Parse error' } })); }
    finally { inFlight--; maybeExit(); }
  });
  rl.on('close', () => { closed = true; maybeExit(); });
}
startServer();
