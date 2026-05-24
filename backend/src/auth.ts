import type { Context, MiddlewareHandler } from 'hono';
import { HTTPException } from 'hono/http-exception';
import type { Env, OryIdentity, Variables, AppUser } from './types';
import { isBootstrapAdmin } from './types';

// demo.<base64url(JSON {email, exp})>.<base64url(hmac)>
const DEMO_TOKEN_PREFIX = 'demo.';

export const oryAuth: MiddlewareHandler<{ Bindings: Env; Variables: Variables }> = async (c, next) => {
  const auth = c.req.header('Authorization');
  if (!auth || !auth.startsWith('Bearer ')) {
    throw new HTTPException(401, { message: 'missing bearer token' });
  }
  const token = auth.slice('Bearer '.length).trim();
  if (!token) throw new HTTPException(401, { message: 'empty bearer token' });

  if (token.startsWith(DEMO_TOKEN_PREFIX)) {
    const demoEmail = await verifyDemoToken(c.env, token);
    if (!demoEmail) throw new HTTPException(401, { message: 'invalid demo session' });
    c.set('oryIdentity', synthesizeDemoIdentity(demoEmail));
    c.set('isDemo', true);
    await next();
    return;
  }

  const whoami = await fetch(`${c.env.ORY_SDK_URL}/sessions/whoami`, {
    headers: { 'X-Session-Token': token, accept: 'application/json' },
  });
  if (whoami.status === 401 || whoami.status === 403) {
    throw new HTTPException(401, { message: 'invalid session' });
  }
  if (!whoami.ok) {
    throw new HTTPException(502, { message: `ory whoami failed: ${whoami.status}` });
  }
  const session = (await whoami.json()) as { identity: OryIdentity };
  c.set('oryIdentity', session.identity);
  c.set('isDemo', false);
  await next();
};

export function parseDemoUsers(env: Env): Map<string, string> {
  const out = new Map<string, string>();
  for (const pair of (env.DEMO_USERS ?? '').split(',')) {
    const trimmed = pair.trim();
    if (!trimmed) continue;
    const idx = trimmed.indexOf(':');
    if (idx <= 0) continue;
    const email = trimmed.slice(0, idx).trim().toLowerCase();
    const password = trimmed.slice(idx + 1);
    if (!email || !password) continue;
    out.set(email, password);
  }
  return out;
}

export function isDemoModeEnabled(env: Env): boolean {
  return parseDemoUsers(env).size > 0;
}

// 24h TTL — long enough for an App Review session, short enough that a
// leaked token expires quickly.
export async function mintDemoToken(env: Env, email: string, ttlSec = 24 * 3600): Promise<string> {
  const payload = { email: email.toLowerCase(), exp: Math.floor(Date.now() / 1000) + ttlSec };
  const payloadB64 = base64UrlEncode(new TextEncoder().encode(JSON.stringify(payload)));
  const sig = await hmac(env, payloadB64);
  return `${DEMO_TOKEN_PREFIX}${payloadB64}.${sig}`;
}

// Re-checks the email against the live DEMO_USERS on every call, so clearing
// the env var invalidates outstanding tokens immediately.
async function verifyDemoToken(env: Env, token: string): Promise<string | null> {
  if (!isDemoModeEnabled(env)) return null;
  const body = token.slice(DEMO_TOKEN_PREFIX.length);
  const dot = body.indexOf('.');
  if (dot < 0) return null;
  const payloadB64 = body.slice(0, dot);
  const sig = body.slice(dot + 1);
  const expected = await hmac(env, payloadB64);
  if (!timingSafeEqual(expected, sig)) return null;
  let parsed: { email?: unknown; exp?: unknown };
  try {
    parsed = JSON.parse(new TextDecoder().decode(base64UrlDecode(payloadB64)));
  } catch {
    return null;
  }
  if (typeof parsed.email !== 'string' || typeof parsed.exp !== 'number') return null;
  if (parsed.exp < Math.floor(Date.now() / 1000)) return null;
  if (!parsed.email) return null;
  if (!parseDemoUsers(env).has(parsed.email.toLowerCase())) return null;
  return parsed.email.toLowerCase();
}

// `demo:` prefix can never collide with a real Ory UUID.
function synthesizeDemoIdentity(email: string): OryIdentity {
  const localPart = email.split('@')[0] ?? 'demo';
  return {
    id: `demo:${email}`,
    traits: {
      email,
      name: { first: localPart, last: '' },
    },
    verifiable_addresses: [{ verified: true, value: email }],
  };
}

async function hmac(env: Env, data: string): Promise<string> {
  if (!env.MEDIA_SIGNING_SECRET) {
    throw new Error('MEDIA_SIGNING_SECRET is not set (also used to sign demo tokens)');
  }
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    'raw',
    enc.encode(env.MEDIA_SIGNING_SECRET),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const sigBytes = await crypto.subtle.sign('HMAC', key, enc.encode(data));
  return base64UrlEncode(new Uint8Array(sigBytes));
}

function base64UrlEncode(bytes: Uint8Array): string {
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
}

function base64UrlDecode(s: string): Uint8Array {
  const padded = s.replaceAll('-', '+').replaceAll('_', '/') + '==='.slice((s.length + 3) % 4);
  const bin = atob(padded);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export const requireUser: MiddlewareHandler<{ Bindings: Env; Variables: Variables }> = async (c, next) => {
  const ory = c.get('oryIdentity');
  const row = await c.env.DB
    .prepare('SELECT id, ory_id, email, username, display_name, avatar_key, is_admin, created_at FROM users WHERE ory_id = ?')
    .bind(ory.id)
    .first<AppUser>();
  if (!row) {
    return c.json({ error: 'needs_finalize', message: 'call /me/finalize to complete signup' }, 409);
  }
  if (!row.is_admin && isBootstrapAdmin(c.env, row.email)) {
    await c.env.DB.prepare('UPDATE users SET is_admin = 1 WHERE id = ?').bind(row.id).run();
    row.is_admin = 1;
  }
  c.set('user', row);
  await next();
};

export const requireAdmin: MiddlewareHandler<{ Bindings: Env; Variables: Variables }> = async (c, next) => {
  if (!c.get('user').is_admin) throw new HTTPException(403, { message: 'admin only' });
  await next();
};

export function bearerOryId(c: Context<{ Bindings: Env; Variables: Variables }>): string {
  return c.get('oryIdentity').id;
}
