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
const GROK_DEFAULT_DIR = path.join(HOME, '.grok');
const GROK_BILLING_URL = 'https://cli-chat-proxy.grok.com/v1/billing?format=credits';
const GROK_SETTINGS_URL = 'https://cli-chat-proxy.grok.com/v1/settings';

const POLL_INTERVAL_MS = 5 * 60 * 1000;
const MAX_BACKOFF_MS = 30 * 60 * 1000;
const MIN_MANUAL_REFRESH_MS = 60 * 1000;

const expandHome = (p) => (p.startsWith('~') ? path.join(HOME, p.slice(1)) : p);
const collapseHome = (p) => (p.startsWith(HOME) ? `~${p.slice(HOME.length)}` : p);
const normalizeDir = (p) => path.resolve(expandHome(p.trim())).replace(/\/+$/, '');

// ---------- persistence ----------

function loadAccounts() {
  const fallback = [{ provider: 'claude', configDir: DEFAULT_CONFIG_DIR }];
  if (!existsSync(ACCOUNTS_FILE)) return fallback;
  // Codex stays in the macOS app. Claude and Grok are polled here.
  const saved = JSON.parse(readFileSync(ACCOUNTS_FILE, 'utf8'))
    .filter((a) => ['claude', 'grok'].includes(a.provider ?? 'claude'))
    .map((a) => ({ provider: a.provider ?? 'claude', configDir: normalizeDir(a.configDir) }));
  return saved.length > 0 ? saved : fallback;
}

function saveAccounts() {
  const data = [...state.values()].map((entry) => ({
    provider: entry.provider,
    configDir: collapseHome(entry.configDir),
  }));
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

function createEntry(provider, dir, cached) {
  return {
    provider,
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

function readGrokCredentials(dir) {
  try {
    const data = JSON.parse(readFileSync(path.join(dir, 'auth.json'), 'utf8'));
    const entries = Object.values(data).filter((entry) => entry?.key);
    entries.sort((a, b) => String(b.expires_at ?? '').localeCompare(String(a.expires_at ?? '')));
    const entry = entries[0];
    if (!entry) return null;
    return { accessToken: entry.key, email: entry.email ?? null, expiresAt: entry.expires_at ?? null };
  } catch {
    return null;
  }
}

function grokAmount(value) {
  if (typeof value === 'number') return value;
  if (value && typeof value.val === 'number') return value.val;
  return null;
}

function grokLimits(body) {
  const config = body.config ?? body;
  const period = config.currentPeriod ?? {};
  const periodType = period.type ?? '';
  const resetsAt = period.end ?? config.billingPeriodEnd ?? null;
  const poolLabel = periodType.includes('MONTH') ? 'Monthly limit' : 'Weekly limit';
  const limits = [];

  const creditUsed = grokAmount(config.creditUsagePercent);
  const monthlyCap = grokAmount(config.monthlyLimit);
  const monthlyUsed = grokAmount(config.used);
  if (creditUsed != null) {
    limits.push({ kind: 'weekly_all', label: poolLabel, usedPercent: creditUsed, resetsAt });
  } else if (monthlyCap > 0 && monthlyUsed != null) {
    limits.push({ kind: 'weekly_all', label: 'Monthly limit', usedPercent: (monthlyUsed / monthlyCap) * 100, resetsAt });
  } else if (resetsAt) {
    limits.push({ kind: 'weekly_all', label: poolLabel, usedPercent: 0, resetsAt });
  }

  const onDemandCap = grokAmount(config.onDemandCap);
  if (onDemandCap > 0) {
    const onDemandUsed = grokAmount(config.onDemandUsed) ?? 0;
    limits.push({
      kind: 'weekly_scoped',
      label: 'On-demand',
      usedPercent: (onDemandUsed / onDemandCap) * 100,
      resetsAt,
    });
  }
  return limits;
}

async function refresh(dir) {
  const entry = state.get(dir);
  if (!entry || entry.inFlight) return;
  entry.inFlight = true;

  try {
    if (entry.provider === 'grok') await refreshGrok(entry);
    else await refreshClaude(entry);
  } catch (err) {
    entry.error = `Request failed: ${err.message}`;
    entry.nextFetchAt = Date.now() + POLL_INTERVAL_MS;
  } finally {
    entry.inFlight = false;
  }
}

async function refreshGrok(entry) {
  const creds = readGrokCredentials(entry.configDir);
  if (!creds) {
    entry.error = 'No login found in auth.json';
    entry.nextFetchAt = Date.now() + POLL_INTERVAL_MS;
    return;
  }
  entry.email = creds.email ?? entry.email;
  if (creds.expiresAt && Date.parse(creds.expiresAt) < Date.now()) {
    entry.error = 'Token expired, start Grok to renew it';
    entry.nextFetchAt = Date.now() + 60 * 1000;
    return;
  }

  const headers = {
    Authorization: `Bearer ${creds.accessToken}`,
    Accept: 'application/json',
    'X-XAI-Token-Auth': 'xai-grok-cli',
  };
  const billingRes = await fetch(GROK_BILLING_URL, { headers, signal: AbortSignal.timeout(15000) });
  try {
    const settingsRes = await fetch(GROK_SETTINGS_URL, { headers, signal: AbortSignal.timeout(15000) });
    if (settingsRes.ok) {
      const settings = await settingsRes.json();
      entry.plan = settings.subscription_tier_display ?? entry.plan;
    }
  } catch {
    // The plan name is optional. A settings failure still leaves the usage bar.
  }

  if (billingRes.status === 429) {
    entry.error = 'Rate limited, retrying later';
    entry.backoffMs = Math.min(entry.backoffMs * 2, MAX_BACKOFF_MS);
    entry.nextFetchAt = Date.now() + entry.backoffMs;
    return;
  }
  if (!billingRes.ok) {
    entry.error = billingRes.status === 401 ? 'Token rejected (401)' : `Usage request failed (${billingRes.status})`;
    entry.nextFetchAt = Date.now() + POLL_INTERVAL_MS;
    return;
  }

  const limits = grokLimits(await billingRes.json());
  if (limits.length === 0) {
    entry.error = 'Usage response had no limit';
    entry.nextFetchAt = Date.now() + POLL_INTERVAL_MS;
    return;
  }
  entry.limits = limits;
  entry.fetchedAt = Date.now();
  entry.error = null;
  entry.backoffMs = POLL_INTERVAL_MS;
  entry.nextFetchAt = Date.now() + POLL_INTERVAL_MS;
  saveCache();
}

async function refreshClaude(entry) {
  const dir = entry.configDir;
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

function discoverConfigDirs(provider) {
  const prefix = provider === 'grok' ? '.grok' : '.claude';
  const marker = provider === 'grok' ? 'auth.json' : 'settings.json';
  return readdirSync(HOME)
    .filter((name) => name.startsWith(prefix))
    .map((name) => path.join(HOME, name))
    .filter((dir) => {
      try {
        return statSync(dir).isDirectory() && existsSync(path.join(dir, marker));
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
      provider: e.provider,
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
      const provider = url.searchParams.get('provider') === 'grok' ? 'grok' : 'claude';
      return send(res, 200, { candidates: discoverConfigDirs(provider) });
    }

    if (req.method === 'POST' && url.pathname === '/api/accounts') {
      const provider = url.searchParams.get('provider') ?? 'claude';
      if (provider !== 'claude' && provider !== 'grok') {
        return send(res, 400, { error: 'This server supports Claude and Grok accounts' });
      }
      const configDir = url.searchParams.get('configDir') ?? (await readBody(req)).configDir;
      if (!configDir) return send(res, 400, { error: 'configDir is required' });
      const dir = normalizeDir(configDir);
      if (!existsSync(dir)) return send(res, 400, { error: `${collapseHome(dir)} does not exist` });
      if (state.has(dir)) return send(res, 409, { error: 'Account already added' });
      const hasLogin = provider === 'grok' ? readGrokCredentials(dir) : await readCredentials(dir);
      if (!hasLogin) {
        const what = provider === 'grok' ? 'Grok login' : 'Claude Code credentials';
        return send(res, 400, { error: `No ${what} found for ${collapseHome(dir)}` });
      }
      state.set(dir, createEntry(provider, dir));
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
for (const account of loadAccounts()) {
  state.set(account.configDir, createEntry(account.provider, account.configDir, cache[account.configDir]));
}

// Stagger the initial requests so accounts don't all hit the endpoint at once.
[...state.values()].forEach((entry, i) => {
  entry.nextFetchAt = Date.now() + i * 2000;
});
tick();
setInterval(tick, 1000);

server.listen(PORT, '127.0.0.1', () => {
  console.log(`Agents Monitor running at http://localhost:${PORT}`);
});
