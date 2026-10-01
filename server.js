import { createHash } from 'node:crypto';
import { execFile } from 'node:child_process';
import { existsSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { homedir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const ACCOUNTS_FILE = path.join(ROOT, 'accounts.json');
const CACHE_FILE = path.join(ROOT, '.usage-cache.json');
const INDEX_FILE = path.join(ROOT, 'public', 'index.html');
const PORT = Number(process.env.PORT) || 4747;
const HOME = homedir();
const DEFAULT_CONFIG_DIR = path.join(HOME, '.claude');
const USAGE_URL = 'https://api.anthropic.com/api/oauth/usage';

const POLL_INTERVAL_MS = 5 * 60 * 1000;
const MAX_BACKOFF_MS = 30 * 60 * 1000;
const MIN_MANUAL_REFRESH_MS = 60 * 1000;

const expandHome = (p) => (p.startsWith('~') ? path.join(HOME, p.slice(1)) : p);
const collapseHome = (p) => (p.startsWith(HOME) ? `~${p.slice(HOME.length)}` : p);
const normalizeDir = (p) => path.resolve(expandHome(p.trim())).replace(/\/+$/, '');

// ---------- persistence ----------

function loadAccounts() {
  if (!existsSync(ACCOUNTS_FILE)) return [DEFAULT_CONFIG_DIR];
  // The browser version only speaks to Claude; Codex accounts are handled by the macOS app.
  return JSON.parse(readFileSync(ACCOUNTS_FILE, 'utf8'))
    .filter((a) => (a.provider ?? 'claude') === 'claude')
    .map((a) => normalizeDir(a.configDir));
}

function saveAccounts() {
  const data = [...state.keys()].map((dir) => ({ provider: 'claude', configDir: collapseHome(dir) }));
  writeFileSync(ACCOUNTS_FILE, `${JSON.stringify(data, null, 2)}\n`);
}

function loadCache() {
  try {
    return JSON.parse(readFileSync(CACHE_FILE, 'utf8'));
  } catch {
    return {};
  }
}

function saveCache() {
  const data = {};
  for (const [dir, s] of state) {
    if (s.limits) data[dir] = { limits: s.limits, fetchedAt: s.fetchedAt };
  }
  writeFileSync(CACHE_FILE, JSON.stringify(data));
}

// ---------- credentials ----------

// Claude Code stores OAuth credentials in the macOS keychain. The default instance
// (~/.claude) uses "Claude Code-credentials"; any CLAUDE_CONFIG_DIR instance appends
// the first 8 hex chars of sha256(configDir).
function keychainServices(dir) {
  const hash = createHash('sha256').update(dir).digest('hex').slice(0, 8);
  const suffixed = `Claude Code-credentials-${hash}`;
  return dir === DEFAULT_CONFIG_DIR ? ['Claude Code-credentials', suffixed] : [suffixed];
}

function readKeychain(service) {
  return new Promise((resolve) => {
    execFile('security', ['find-generic-password', '-s', service, '-w'], (err, stdout) => {
      if (err) return resolve(null);
      try {
        resolve(JSON.parse(stdout).claudeAiOauth ?? null);
      } catch {
        resolve(null);
      }
    });
  });
}

async function readCredentials(dir) {
  const candidates = await Promise.all(keychainServices(dir).map(readKeychain));
  // Pick the freshest token when several entries exist (old ones linger after re-logins).
  return (
    candidates
      .filter((c) => c?.accessToken)
      .sort((a, b) => (b.expiresAt ?? 0) - (a.expiresAt ?? 0))[0] ?? null
  );
}

function readProfile(dir) {
  const file = dir === DEFAULT_CONFIG_DIR ? path.join(HOME, '.claude.json') : path.join(dir, '.claude.json');
  try {
    const account = JSON.parse(readFileSync(file, 'utf8')).oauthAccount ?? {};
    return { email: account.emailAddress ?? null };
  } catch {
    return { email: null };
  }
}

// ---------- usage polling ----------

const state = new Map();

function createEntry(dir, cached) {
  return {
    configDir: dir,
    email: null,
    plan: null,
    limits: cached?.limits ?? null,
    fetchedAt: cached?.fetchedAt ?? null,
    error: null,
    nextFetchAt: 0,
    backoffMs: POLL_INTERVAL_MS,
    inFlight: false,
  };
}

async function refresh(dir) {
  const entry = state.get(dir);
  if (!entry || entry.inFlight) return;
  entry.inFlight = true;

  try {
    entry.email = readProfile(dir).email;
    const creds = await readCredentials(dir);
    if (!creds) {
      entry.error = 'No credentials found in keychain';
      entry.nextFetchAt = Date.now() + POLL_INTERVAL_MS;
      return;
    }
    entry.plan = creds.subscriptionType ?? null;

    if (creds.expiresAt && creds.expiresAt < Date.now()) {
      // Refreshing here would rotate the refresh token behind Claude Code's back.
      entry.error = 'Token expired, start this Claude instance to renew it';
      entry.nextFetchAt = Date.now() + 60 * 1000;
      return;
    }

    const res = await fetch(USAGE_URL, {
      headers: {
        Authorization: `Bearer ${creds.accessToken}`,
        'anthropic-beta': 'oauth-2025-04-20',
        'Content-Type': 'application/json',
      },
      signal: AbortSignal.timeout(15000),
    });

    if (res.status === 429) {
      entry.error = 'Rate limited, retrying later';
      entry.backoffMs = Math.min(entry.backoffMs * 2, MAX_BACKOFF_MS);
      entry.nextFetchAt = Date.now() + entry.backoffMs;
      return;
    }
    if (!res.ok) {
      entry.error = res.status === 401 ? 'Token rejected (401)' : `Usage request failed (${res.status})`;
      entry.nextFetchAt = Date.now() + POLL_INTERVAL_MS;
      return;
    }

    const body = await res.json();
    entry.limits = normalizeLimits(body);
    entry.fetchedAt = Date.now();
    entry.error = null;
    entry.backoffMs = POLL_INTERVAL_MS;
    entry.nextFetchAt = Date.now() + POLL_INTERVAL_MS;
    saveCache();
  } catch (err) {
    entry.error = `Request failed: ${err.message}`;
    entry.nextFetchAt = Date.now() + POLL_INTERVAL_MS;
  } finally {
    entry.inFlight = false;
  }
}

function normalizeLimits(body) {
  if (Array.isArray(body.limits) && body.limits.length > 0) {
    return body.limits.map((l) => ({
      kind: l.kind,
      label: limitLabel(l),
      usedPercent: l.percent ?? 0,
      resetsAt: l.resets_at ?? null,
    }));
  }
  // Fallback for responses without the "limits" array.
  const legacy = [
    ['weekly_all', '7-day limit', body.seven_day],
    ['session', '5-hour limit', body.five_hour],
    ['weekly_scoped', '7-day Opus', body.seven_day_opus],
    ['weekly_scoped', '7-day Sonnet', body.seven_day_sonnet],
  ];
  return legacy
    .filter(([, , v]) => v)
    .map(([kind, label, v]) => ({ kind, label, usedPercent: v.utilization ?? 0, resetsAt: v.resets_at ?? null }));
}

function limitLabel(limit) {
  if (limit.kind === 'session') return '5-hour limit';
  if (limit.kind === 'weekly_all') return '7-day limit';
  const scope = limit.scope?.model?.display_name ?? limit.scope?.surface?.display_name;
  return scope ? `7-day ${scope}` : limit.kind.replace(/_/g, ' ');
}

function tick() {
  const now = Date.now();
  for (const [dir, entry] of state) {
    if (now >= entry.nextFetchAt) refresh(dir);
  }
}

// ---------- discovery ----------

function discoverConfigDirs() {
  return readdirSync(HOME)
    .filter((name) => name.startsWith('.claude'))
    .map((name) => path.join(HOME, name))
    .filter((dir) => {
      try {
        return statSync(dir).isDirectory() && existsSync(path.join(dir, 'settings.json'));
      } catch {
        return false;
      }
    })
    .filter((dir) => !state.has(dir))
    .map(collapseHome);
}

// ---------- http ----------

function publicState() {
  return {
    now: Date.now(),
    accounts: [...state.values()].map((e) => ({
      configDir: collapseHome(e.configDir),
      email: e.email,
      plan: e.plan,
      limits: e.limits,
      fetchedAt: e.fetchedAt,
      error: e.error,
      loading: e.inFlight && !e.limits,
    })),
  };
}

async function readBody(req) {
  let raw = '';
  for await (const chunk of req) raw += chunk;
  return raw ? JSON.parse(raw) : {};
}

function send(res, status, data) {
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(data));
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);

  try {
    if (req.method === 'GET' && url.pathname === '/') {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      return res.end(readFileSync(INDEX_FILE));
    }

    if (req.method === 'GET' && url.pathname === '/api/state') {
      return send(res, 200, publicState());
    }

    if (req.method === 'GET' && url.pathname === '/api/candidates') {
      return send(res, 200, { candidates: discoverConfigDirs() });
    }

    if (req.method === 'POST' && url.pathname === '/api/accounts') {
      const configDir = url.searchParams.get('configDir') ?? (await readBody(req)).configDir;
      if (!configDir) return send(res, 400, { error: 'configDir is required' });
      const dir = normalizeDir(configDir);
      if (!existsSync(dir)) return send(res, 400, { error: `${collapseHome(dir)} does not exist` });
      if (state.has(dir)) return send(res, 409, { error: 'Account already added' });
      if (!(await readCredentials(dir))) {
        return send(res, 400, { error: `No Claude Code credentials found for ${collapseHome(dir)}` });
      }
      state.set(dir, createEntry(dir));
      saveAccounts();
      await refresh(dir);
      return send(res, 201, publicState());
    }

    if (req.method === 'DELETE' && url.pathname === '/api/accounts') {
      const dir = normalizeDir(url.searchParams.get('configDir') ?? '');
      if (!state.delete(dir)) return send(res, 404, { error: 'Unknown account' });
      saveAccounts();
      saveCache();
      return send(res, 200, publicState());
    }

    if (req.method === 'POST' && url.pathname === '/api/refresh') {
      for (const entry of state.values()) {
        if (!entry.fetchedAt || Date.now() - entry.fetchedAt > MIN_MANUAL_REFRESH_MS) entry.nextFetchAt = 0;
      }
      tick();
      return send(res, 202, { ok: true });
    }

    send(res, 404, { error: 'Not found' });
  } catch (err) {
    send(res, 500, { error: err.message });
  }
});

const cache = loadCache();
for (const dir of loadAccounts()) state.set(dir, createEntry(dir, cache[dir]));

// Stagger the initial requests so accounts don't all hit the endpoint at once.
[...state.values()].forEach((entry, i) => {
  entry.nextFetchAt = Date.now() + i * 2000;
});
tick();
setInterval(tick, 1000);

server.listen(PORT, '127.0.0.1', () => {
  console.log(`Agents Monitor running at http://localhost:${PORT}`);
});
