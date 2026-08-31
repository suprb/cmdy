#!/usr/bin/env node

/**
 * cmdy Bridge — MCP stdio bridge.
 *
 * Bridges an MCP client over stdio to the cmdy Bridge HTTP
 * server (port 3457 by default). Every request carries the Bridge process's
 * per-launch bearer credential, and every /execute call carries the
 * BRIDGE_SESSION_ID so the bridge knows which target to dispatch to.
 *
 * Install:
 *   claude mcp add --scope user bridge -- node /absolute/path/to/this/index.js
 *
 * Env vars read:
 *   BRIDGE_SESSION_ID    — set by the shell hook on session register
 *   BRAINCELL_BRIDGE_PORT — defaults to 3457
 *   BRAINCELL_BRIDGE_TOKEN — explicit standalone override (64 hex chars)
 *   BRAINCELL_BRIDGE_TOKEN_FILE — private per-launch token file
 */

const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');
const readline = require('readline');
const { execSync } = require('child_process');

function loadProductIdentity() {
  const candidates = [
    path.join(__dirname, 'product-identity.js'),
    path.join(__dirname, '..', '..', '..', '..', '..', '..',
      'Identity', 'Node', 'product-identity.js'),
  ];
  for (const candidate of candidates) {
    try { return require(candidate); } catch {}
  }
  throw new Error('Product identity module is missing');
}

const PRODUCT = loadProductIdentity();
const SERVER_NAME = PRODUCT.mcpServerName('bridge');
const MAX_RESPONSE_BYTES = 32 * 1024 * 1024;
const PORT_FILE = process.env.BRAINCELL_BRIDGE_PORT_FILE
  || '/tmp/braincell-bridge.port';
const TOKEN_FILE = process.env.BRAINCELL_BRIDGE_TOKEN_FILE
  || '/tmp/braincell-bridge.token';
const TOKEN_PATTERN = /^[0-9a-f]{64}$/i;

// Port resolution.
//
// Bridge writes its actual listening port to /tmp/braincell-bridge.port on
// startup (auto-bumps from 3457 when port is busy). The shell hook reads
// this. mcp/index.js used to read ONLY BRAINCELL_BRIDGE_PORT env var, which
// Claude Code captured at its startup — if the bridge restarted on a
// different port (auto-bump), every tool call quietly hit the wrong port
// and got connection-refused → "no adapter" looking error.
//
// Fix: every HTTP call asks `currentPort()` which prefers /tmp/braincell-
// bridge.port (live), falls back to env var, falls back to 3457. Cheap
// (one fs.readFileSync per call). Self-heals across bridge restarts.
function currentPort() {
  try {
    const stat = fs.lstatSync(PORT_FILE);
    if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 1024) {
      throw new Error('invalid port file');
    }
    const txt = fs.readFileSync(PORT_FILE, 'utf8').trim();
    const p = Number(txt);
    if (Number.isInteger(p) && p > 0 && p < 65536) return p;
  } catch {}
  const envPort = Number(process.env.BRAINCELL_BRIDGE_PORT || '3457');
  return Number.isInteger(envPort) && envPort > 0 && envPort < 65536
    ? envPort : 3457;
}

// Authentication resolution intentionally has no fixed or tokenless fallback.
// The app rotates this file on every launch; reading it per request self-heals
// an already-running MCP stdio process after the Bridge restarts.
function currentToken() {
  const configured = process.env.BRAINCELL_BRIDGE_TOKEN;
  if (configured) {
    if (!TOKEN_PATTERN.test(configured)) {
      throw new Error('BRAINCELL_BRIDGE_TOKEN must be 64 hexadecimal characters');
    }
    return configured.toLowerCase();
  }
  let stat;
  try {
    stat = fs.lstatSync(TOKEN_FILE);
  } catch {
    throw new Error('Bridge authentication token is unavailable; start cmdy Bridge first');
  }
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 1024
      || (stat.mode & 0o077) !== 0) {
    throw new Error('Bridge authentication token file is not a private regular file');
  }
  const token = fs.readFileSync(TOKEN_FILE, 'utf8').trim();
  if (!TOKEN_PATTERN.test(token)) {
    throw new Error('Bridge authentication token file is malformed');
  }
  return token.toLowerCase();
}

// Session id resolution.
//
// Old design: read BRIDGE_SESSION_ID at process start, use forever. Broke
// whenever the bridge restarted — Claude Code's cached env var pointed at a
// session id that no longer existed in the new bridge's registry, leading to
// repeated "no adapter found for session" errors.
//
// New design: derive on-demand. Try the env var first (cheap, usually right);
// if the bridge says it doesn't exist, walk our process tree to find the shell
// pid and look up the live session for that shell from /sessions. Cache the
// resolved id but invalidate it on any "not bound" / "no adapter" error so a
// stale cache self-heals.
let cachedSessionId = process.env.BRIDGE_SESSION_ID || null;

function getShellPid() {
  // mcp/index.js is spawned by Claude Code, which is spawned by the shell.
  // Walking ppid once gets Claude; once more gets the shell. ps is portable
  // enough for macOS — we ship Mac-only anyway.
  try {
    const claudePid = process.ppid;
    const out = execSync(`ps -o ppid= -p ${claudePid}`, {
      encoding: 'utf8',
      timeout: 2000,
      maxBuffer: 64 * 1024,
    }).trim();
    const shellPid = parseInt(out, 10);
    return Number.isFinite(shellPid) && shellPid > 1 ? shellPid : null;
  } catch {
    return null;
  }
}

async function resolveSessionId() {
  // Validate cached id (handles bridge restart where session got a new
  // deterministic id for the same shell). 404 means cache is stale.
  if (cachedSessionId) {
    try {
      const r = await httpJSON(
        'GET', `/sessions/${encodeURIComponent(cachedSessionId)}/binding`, null);
      if (r && (r.bound === true || r.bound === false)) {
        return cachedSessionId;
      }
    } catch {}
  }
  // Cache miss / stale — look up by shell pid via /sessions.
  const shellPid = getShellPid();
  if (shellPid) {
    try {
      const list = await httpJSON('GET', '/sessions', null);
      const arr = (list && list.sessions) || [];
      const match = arr.find((s) => s.pid === shellPid);
      if (match && match.id) {
        cachedSessionId = match.id;
        return cachedSessionId;
      }
    } catch {}
  }
  // Last-resort fallback: whatever was in the env var, even if it doesn't
  // resolve (caller will get a clearer error from the bridge).
  return process.env.BRIDGE_SESSION_ID || null;
}

// ── HTTP helpers ────────────────────────────────────────────────────────────

function httpJSON(method, path, body) {
  return new Promise((resolve, reject) => {
    const data = body ? JSON.stringify(body) : null;
    const token = currentToken();
    const headers = { Authorization: `Bearer ${token}` };
    if (data) {
      headers['Content-Type'] = 'application/json';
      headers['Content-Length'] = Buffer.byteLength(data);
    }
    const req = http.request({
      hostname: '127.0.0.1',
      port: currentPort(),
      path,
      method,
      headers,
    }, (res) => {
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
        if (bytes > MAX_RESPONSE_BYTES) {
          res.destroy();
          fail(new Error('Bridge response exceeds 32 MB'));
          return;
        }
        chunks.push(chunk);
      });
      res.on('error', fail);
      res.on('end', () => {
        if (settled) return;
        settled = true;
        const text = Buffer.concat(chunks).toString('utf8');
        if ((res.statusCode || 500) >= 400) {
          reject(new Error(`Bridge HTTP ${res.statusCode}: ${text.slice(0, 1000)}`));
          return;
        }
        try { resolve(JSON.parse(text)); }
        catch (e) { resolve({ error: text || e.message }); }
      });
    });
    req.on('error', (e) => reject(new Error(`Bridge not reachable on :${currentPort()} (${e.message})`)));
    req.setTimeout(60000, () => { req.destroy(); reject(new Error('Bridge request timeout')); });
    if (data) req.write(data);
    req.end();
  });
}

// ── Tool list (re-evaluated on every list call so binding state is live) ────

async function isOwningSession() {
  // We only advertise tools when this stdio bridge "owns" the calling terminal.
  // Owning means we can resolve a session id (via env or shell-pid lookup) AND
  // that session has an actual binding (otherwise tools would just error at
  // call time and pollute Claude's tool surface for nothing).
  const sid = await resolveSessionId();
  if (!sid) return false;
  try {
    const r = await httpJSON(
      'GET', `/sessions/${encodeURIComponent(sid)}/binding`, null);
    return r && r.bound === true;
  } catch {
    return false;
  }
}

async function getTools() {
  if (!(await isOwningSession())) return [];
  try {
    const list = await httpJSON('GET', '/tools', null);
    return Array.isArray(list) ? list : [];
  } catch {
    return [];
  }
}

// ── MCP protocol handlers ───────────────────────────────────────────────────

// ── Binding-change notifier ────────────────────────────────────────────────
//
// Claude Code reads the tool list ONCE per stdio session. If the user starts
// `claude` before binding, our tools/list returns [] and Claude caches that.
// We poll the bridge for binding flips and emit `notifications/tools/list_changed`
// when state transitions, prompting Claude to re-query.
let lastOwningState = false;
function startBindingWatcher() {
  const timer = setInterval(async () => {
    let owning = false;
    try { owning = await isOwningSession(); } catch { owning = false; }
    if (owning !== lastOwningState) {
      lastOwningState = owning;
      // MCP notification — no `id`, no response expected.
      console.log(JSON.stringify({
        jsonrpc: '2.0',
        method: 'notifications/tools/list_changed',
      }));
    }
  }, 1500);
  timer.unref();
}

function handleInitialize(id) {
  // Kick off binding watcher on first initialize so we don't poll before Claude
  // is even talking to us.
  startBindingWatcher();
  return {
    jsonrpc: '2.0',
    id,
    result: {
      protocolVersion: '2024-11-05',
      // listChanged: true — we push notifications/tools/list_changed when the
      // user binds/unbinds in the popover, so Claude re-queries instead of
      // caching the empty list it got at startup.
      capabilities: { tools: { listChanged: true } },
      serverInfo: { name: SERVER_NAME, version: '0.1.0' },
    },
  };
}

async function handleListTools(id) {
  const tools = await getTools();
  return { jsonrpc: '2.0', id, result: { tools } };
}

async function handleCallTool(id, params) {
  const { name, arguments: args = {} } = params || {};
  if (typeof name !== 'string' || name.length === 0 || name.length > 128) {
    return {
      jsonrpc: '2.0',
      id,
      error: { code: -32602, message: 'Invalid tool name' },
    };
  }

  let sid = await resolveSessionId();
  if (!sid) {
    return {
      jsonrpc: '2.0',
      id,
      error: {
        code: -32000,
        message: 'No Bridge session for this shell. Open the agent from a cmdy pane with Bridge enabled.',
      },
    };
  }

  let result;
  try {
    result = await httpJSON('POST', '/execute', {
      tool: name, arguments: args, sessionId: sid,
    });
  } catch (e) {
    return { jsonrpc: '2.0', id, error: { code: -32000, message: e.message } };
  }

  // Self-heal: if the bridge says "no adapter" or "not bound", the cached
  // session id is stale (e.g. bridge restarted between this and last call).
  // Invalidate cache, re-resolve, retry once.
  if (result && typeof result === 'object' && typeof result.error === 'string'
      && /no adapter|not bound/i.test(result.error)) {
    cachedSessionId = null;
    const fresh = await resolveSessionId();
    if (fresh && fresh !== sid) {
      try {
        result = await httpJSON('POST', '/execute', {
          tool: name, arguments: args, sessionId: fresh,
        });
      } catch (e) {
        return { jsonrpc: '2.0', id, error: { code: -32000, message: e.message } };
      }
    }
  }

  // Bridge returns either { result: {...} } on success or { error: "..." } on user-level failure.
  if (result && typeof result === 'object' && 'error' in result) {
    return {
      jsonrpc: '2.0',
      id,
      result: { content: [{ type: 'text', text: String(result.error) }], isError: true },
    };
  }

  const payload = (result && result.result) ? result.result : result;

  // Screenshot tool returns { success, path, size, format } — read the file and return as image.
  if (name.endsWith('screenshot') && payload && payload.path) {
    try {
      const resolved = fs.realpathSync(payload.path);
      const tempRoot = fs.realpathSync(os.tmpdir());
      const tempPrefix = tempRoot.endsWith('/') ? tempRoot : `${tempRoot}/`;
      const filename = resolved.slice(tempPrefix.length);
      const allowedPrefix = ['bridge-shot-', 'mac-shot-', 'native-shot-', 'sim-shot-']
        .some((prefix) => filename.startsWith(prefix));
      if (!resolved.startsWith(tempPrefix) || filename.includes('/')
          || !allowedPrefix || !/\\.(png|jpe?g)$/i.test(filename)) {
        throw new Error('screenshot path is outside the Bridge temp directory');
      }
      const stat = fs.statSync(resolved);
      if (!stat.isFile() || stat.size > 64 * 1024 * 1024) {
        throw new Error('screenshot exceeds 64 MB');
      }
      const data = fs.readFileSync(resolved);
      const fmt = /\\.jpe?g$/i.test(filename) ? 'jpeg' : 'png';
      return {
        jsonrpc: '2.0',
        id,
        result: {
          content: [
            { type: 'text', text: `Screenshot ${data.length} bytes (${fmt}) at ${resolved}` },
            { type: 'image', data: data.toString('base64'), mimeType: `image/${fmt}` },
          ],
        },
      };
    } catch (e) {
      // Fall through to default text rendering below.
    }
  }

  return {
    jsonrpc: '2.0',
    id,
    result: { content: [{ type: 'text', text: JSON.stringify(payload, null, 2) }] },
  };
}

async function handleMessage(msg) {
  const { method, id, params } = msg;
  switch (method) {
    case 'initialize':                return handleInitialize(id);
    case 'initialized':
    case 'notifications/initialized':
    case 'notifications/cancelled':
      return null;
    case 'tools/list':                return await handleListTools(id);
    case 'tools/call':                return await handleCallTool(id, params);
    default:
      if (id == null) return null;
      return { jsonrpc: '2.0', id, error: { code: -32601, message: `Method not found: ${method}` } };
  }
}

// ── stdio loop ──────────────────────────────────────────────────────────────

const rl = readline.createInterface({ input: process.stdin, output: process.stdout, terminal: false });
let inFlight = 0;
let inputClosed = false;
const maybeExit = () => { if (inputClosed && inFlight === 0) process.exit(0); };
rl.on('line', async (line) => {
  inFlight++;
  let msg;
  try { msg = JSON.parse(line); }
  catch (e) {
    console.log(JSON.stringify({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Parse error' } }));
    inFlight--;
    maybeExit();
    return;
  }
  try {
    const resp = await handleMessage(msg);
    if (resp) console.log(JSON.stringify(resp));
  } finally {
    inFlight--;
    maybeExit();
  }
});
rl.on('close', () => { inputClosed = true; maybeExit(); });
