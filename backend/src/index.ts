import { Hono } from 'hono';
import type { Context } from 'hono';
import { cors } from 'hono/cors';
import { logger } from 'hono/logger';
import { HTTPException } from 'hono/http-exception';

import type { Env, Variables, AppUser } from './types';
import { isBootstrapAdmin, isDebugEnabled, getMaxPostMedia, DEFAULT_TENANT_ID, DEMO_TENANT_ID } from './types';
import { oryAuth, requireAdmin, requireUser, isDemoModeEnabled, mintDemoToken, parseDemoUsers } from './auth';
import { signMediaUrl, verifyMediaSignature } from './media';
import { seedImage } from './demo_seed';
import { sendPush } from './push';
import { newId, now, slugifyEmailToUsername } from './util';
import privacyHtml from './pages/privacy.html';
import supportHtml from './pages/support.html';

type App = { Bindings: Env; Variables: Variables };

const app = new Hono<App>();

// Per-request request/response logging — only when DEBUG_LOGGING is on.
// The middleware instance is reused; we just opt in/out per request.
const honoLogger = logger();
app.use('*', async (c, next) => {
  if (isDebugEnabled(c.env)) {
    return honoLogger(c, next);
  }
  await next();
});

app.use('*', cors({
  origin: (origin, c) => {
    if (!origin) return null;
    const env = c.env as Env;
    const allowed = (env.CORS_ORIGINS ?? '')
      .split(',')
      .map((s: string) => s.trim())
      .filter(Boolean);
    return allowed.includes(origin) ? origin : null;
  },
  allowHeaders: ['Authorization', 'Content-Type'],
  allowMethods: ['GET', 'POST', 'PATCH', 'DELETE'],
}));

app.use('*', async (c, next) => {
  if (!c.env.RATE_LIMITER) return next();
  if (c.req.path === '/health') return next();
  const ip = c.req.header('CF-Connecting-IP') ?? c.req.header('X-Forwarded-For') ?? 'unknown';
  const { success } = await c.env.RATE_LIMITER.limit({ key: ip });
  if (!success) throw new HTTPException(429, { message: 'rate limit exceeded' });
  await next();
});

app.onError((err, c) => {
  if (err instanceof HTTPException) return err.getResponse();
  console.error('unhandled', err);
  return c.json({ error: 'internal' }, 500);
});

app.get('/health', (c) => c.json({ ok: true }));

app.get('/config', (c) => c.json({
  demo_mode: isDemoModeEnabled(c.env),
  debug: isDebugEnabled(c.env),
  max_post_media: getMaxPostMedia(c.env),
}));

// 404 (not 401) when demo mode is disabled, so a probing client can't tell
// "wrong password" from "disabled".
app.post('/auth/demo', async (c) => {
  if (!isDemoModeEnabled(c.env)) return c.notFound();
  const body = await c.req.json<{ email?: string; password?: string }>().catch(() => null);
  const email = body?.email?.trim().toLowerCase();
  const password = body?.password ?? '';
  if (!email || !password) throw new HTTPException(400, { message: 'email and password required' });
  const expected = parseDemoUsers(c.env).get(email);
  if (!expected || expected !== password) {
    throw new HTTPException(401, { message: 'invalid demo credentials' });
  }
  const token = await mintDemoToken(c.env, email);
  return c.json({ session_token: token, email });
});

app.get('/privacy', (c) => {
  return new Response(privacyHtml, {
    status: 200,
    headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'public, max-age=300' },
  });
});

app.get('/support', (c) => {
  const rawEmail = (c.env.SUPPORT_EMAIL ?? '').trim();
  const safeEmail = /^[^<>"&\s]+@[^<>"&\s]+$/.test(rawEmail) ? rawEmail : '';
  const contactLink = safeEmail
    ? `<a href="mailto:${safeEmail}">Email us</a>`
    : `Reach out to the admin who installed Familygram for your family`;
  const html = supportHtml.replace('{{CONTACT_LINK}}', contactLink);
  return new Response(html, {
    status: 200,
    headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'public, max-age=300' },
  });
});

// Signed-URL media. A leaked URL stops working once `e` passes.
app.get('/media/:scope/:owner/:filename', async (c) => {
  const key = `${c.req.param('scope')}/${c.req.param('owner')}/${c.req.param('filename')}`;
  const expiresAt = Number(c.req.query('e') ?? 0);
  const signature = c.req.query('s') ?? '';
  if (!(await verifyMediaSignature(c.env, key, expiresAt, signature))) {
    return c.json({ error: 'invalid or expired signature' }, 403);
  }
  // Demo-sandbox seed media is bundled in the Worker, not stored in R2. Serve it
  // directly (still behind the same signed-URL check) so the demo feed has
  // photos without any real family content. See demo_seed.ts / migration 0006.
  if (c.req.param('scope') === 'seed') {
    const bytes = seedImage(c.req.param('filename'));
    if (!bytes) return c.notFound();
    return new Response(bytes, {
      headers: { 'content-type': 'image/png', 'cache-control': 'private, max-age=900' },
    });
  }
  const obj = await c.env.MEDIA.get(key);
  if (!obj) return c.notFound();
  const headers = new Headers();
  obj.writeHttpMetadata(headers);
  headers.set('etag', obj.httpEtag);
  headers.set('cache-control', 'private, max-age=900');
  return new Response(obj.body, { headers });
});

const authed = new Hono<App>();
authed.use('*', oryAuth);

// Idempotent. Allowlist + bootstrap admin check on first call.
authed.post('/me/finalize', async (c) => {
  const ory = c.get('oryIdentity');
  const email = ory.traits.email.toLowerCase();

  const existing = await c.env.DB
    .prepare('SELECT id, ory_id, email, username, display_name, avatar_key, is_admin, is_demo, created_at FROM users WHERE ory_id = ?')
    .bind(ory.id)
    .first<{ id: string; ory_id: string; email: string; username: string; display_name: string; avatar_key: string | null; is_admin: number; is_demo: number; created_at: number }>();
  if (existing) return c.json(await decorateUser(c, existing));

  const isDemo = c.get('isDemo');
  const isAdmin = isBootstrapAdmin(c.env, email);
  // One allowlist row per tenant the email was invited to — redeeming creates
  // a membership for each. Bootstrap admins and demo identities get their
  // fixed tenant even with no allowlist row.
  const entries = (
    await c.env.DB
      .prepare('SELECT tenant_id FROM allowlist WHERE email = ? AND used_by IS NULL')
      .bind(email)
      .all<{ tenant_id: string }>()
  ).results;
  const tenantIds = new Set<string>(entries.map((e) => e.tenant_id));
  if (isDemo) tenantIds.add(DEMO_TENANT_ID);
  else if (isAdmin) tenantIds.add(DEFAULT_TENANT_ID);
  const allowed = tenantIds.size > 0;
  if (!allowed) {
    return c.json({
      error: 'not_allowed',
      email,
      message: `${email} isn't on the family list. Ask an admin to add you.`,
    }, 403);
  }

  const userId = newId();
  const fromName = [ory.traits.name?.first, ory.traits.name?.last].filter(Boolean).join(' ').trim();
  const display_name = fromName || (email.split('@')[0] ?? 'user');
  const username = await uniqueUsername(c.env.DB, email);
  const ts = now();

  // Best-effort avatar import from Google OIDC so we don't depend on Google's CDN at request time.
  let avatarKey: string | null = null;
  if (ory.traits.picture) {
    try {
      const res = await fetch(ory.traits.picture);
      if (res.ok && res.body) {
        const key = `avatars/${userId}/${newId().slice(0, 6)}.jpg`;
        await c.env.MEDIA.put(key, res.body, { httpMetadata: { contentType: 'image/jpeg' } });
        avatarKey = key;
      }
    } catch (e) {
      console.log('avatar import failed', e);
    }
  }

  await c.env.DB.batch([
    c.env.DB
      .prepare('INSERT INTO users (id, ory_id, email, username, display_name, avatar_key, is_admin, is_demo, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)')
      .bind(userId, ory.id, email, username, display_name, avatarKey, isAdmin ? 1 : 0, isDemo ? 1 : 0, ts),
    ...[...tenantIds].map((t) =>
      c.env.DB
        .prepare('INSERT OR IGNORE INTO tenant_members (tenant_id, user_id, role, created_at) VALUES (?, ?, ?, ?)')
        .bind(t, userId, isAdmin ? 'admin' : 'member', ts),
    ),
    c.env.DB
      .prepare('UPDATE allowlist SET used_by = ?, used_at = ? WHERE email = ? AND used_by IS NULL')
      .bind(userId, ts, email),
  ]);

  return c.json(await decorateUser(c, {
    id: userId, ory_id: ory.id, email, username, display_name,
    avatar_key: avatarKey, is_admin: isAdmin ? 1 : 0, is_demo: isDemo ? 1 : 0, created_at: ts,
  }));
});

async function uniqueUsername(db: D1Database, email: string): Promise<string> {
  const base = slugifyEmailToUsername(email);
  for (let i = 0; i < 50; i++) {
    const candidate = i === 0 ? base : `${base}${i}`;
    const taken = await db.prepare('SELECT id FROM users WHERE username = ?').bind(candidate).first();
    if (!taken) return candidate;
  }
  return `${base}_${Math.floor(Math.random() * 1e6)}`;
}

const u = new Hono<App>();
u.use('*', requireUser);

u.get('/me', async (c) => {
  const user = await decorateUser(c, c.get('user') as unknown as Record<string, unknown>);
  return c.json({
    ...user,
    tenants: c.get('tenants').map((t) => ({ id: t.tenant_id, name: t.name, role: t.role })),
    active_tenant_id: c.get('activeTenantId'),
  });
});

// Wipes posts, comments, likes, allowlist row, and user row. Best-effort R2 cleanup.
// Does NOT delete the Ory identity (= the user's Google account, out of our control).
u.delete('/me', async (c) => {
  const me = c.get('user');

  const ownMedia = await c.env.DB
    .prepare(`
      SELECT pm.image_key, pm.thumb_key
      FROM post_media pm
      JOIN posts p ON p.id = pm.post_id
      WHERE p.user_id = ?
    `)
    .bind(me.id)
    .all<{ image_key: string; thumb_key: string }>();
  const r2Keys: string[] = [];
  for (const m of ownMedia.results ?? []) {
    r2Keys.push(m.image_key, m.thumb_key);
  }
  if (me.avatar_key) r2Keys.push(me.avatar_key);

  await c.env.DB.batch([
    c.env.DB.prepare('DELETE FROM likes WHERE user_id = ?').bind(me.id),
    c.env.DB.prepare('DELETE FROM comments WHERE user_id = ?').bind(me.id),
    c.env.DB.prepare('DELETE FROM posts WHERE user_id = ?').bind(me.id),
    c.env.DB.prepare('DELETE FROM device_tokens WHERE user_id = ?').bind(me.id),
    c.env.DB.prepare('DELETE FROM tenant_members WHERE user_id = ?').bind(me.id),
    c.env.DB.prepare('UPDATE allowlist SET used_by = NULL, used_at = NULL WHERE used_by = ?').bind(me.id),
    c.env.DB.prepare('DELETE FROM allowlist WHERE email = ?').bind(me.email),
    c.env.DB.prepare('DELETE FROM users WHERE id = ?').bind(me.id),
  ]);

  c.executionCtx.waitUntil(Promise.all(r2Keys.map((k) => c.env.MEDIA.delete(k).catch(() => {}))).then(() => {}));

  return c.json({ ok: true });
});

u.post('/me/avatar', async (c) => {
  const me = c.get('user');
  const form = await c.req.formData();
  const file = form.get('avatar') as File | string | null;
  if (!file || typeof file === 'string') throw new HTTPException(400, { message: 'avatar file required' });
  if (file.size > 512 * 1024) throw new HTTPException(413, { message: 'avatar > 512 KB' });
  if (!file.type.startsWith('image/')) throw new HTTPException(415, { message: 'avatar must be image/*' });

  // Versioned key so the client cache (cached_network_image) invalidates after change.
  const version = newId().slice(0, 6);
  const key = `avatars/${me.id}/${version}.jpg`;
  await c.env.MEDIA.put(key, file.stream(), { httpMetadata: { contentType: 'image/jpeg' } });

  if (me.avatar_key) c.executionCtx.waitUntil(c.env.MEDIA.delete(me.avatar_key).catch(() => {}));

  await c.env.DB.prepare('UPDATE users SET avatar_key = ? WHERE id = ?').bind(key, me.id).run();
  return c.json(await decorateUser(c, { ...me, avatar_key: key }));
});

// Idempotent: re-registering the same token (re-installs, OS restore) updates
// the user_id binding and last_seen_at. ON CONFLICT keys on the token PK so a
// token that hops from one allowlisted user to another correctly re-binds.
u.post('/me/device-tokens', async (c) => {
  const me = c.get('user');
  const body = await c.req.json<{ token?: string; platform?: string }>().catch(() => null);
  const token = body?.token?.trim();
  const platform = body?.platform?.trim();
  if (!token) throw new HTTPException(400, { message: 'token required' });
  if (token.length > 4096) throw new HTTPException(400, { message: 'token too long' });
  if (platform !== 'ios' && platform !== 'android') {
    throw new HTTPException(400, { message: 'platform must be ios or android' });
  }
  const ts = now();
  await c.env.DB
    .prepare(`
      INSERT INTO device_tokens (token, user_id, platform, created_at, last_seen_at)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(token) DO UPDATE SET
        user_id = excluded.user_id,
        platform = excluded.platform,
        last_seen_at = excluded.last_seen_at
    `)
    .bind(token, me.id, platform, ts, ts)
    .run();
  return c.json({ ok: true });
});

// Client-side diagnostic sink — anything POSTed here lands in `wrangler tail`,
// so we can see what's happening inside the iOS app on TestFlight (where
// debugPrint is stripped and the only other option is Console.app).
u.post('/me/push-diagnostic', async (c) => {
  const me = c.get('user');
  const body = await c.req.json<Record<string, unknown>>().catch(() => ({}));
  if (isDebugEnabled(c.env)) {
    console.log(`push-diag user=${me.id} ${JSON.stringify(body)}`);
  }
  return c.json({ ok: true });
});

// Body-not-path so the FCM token (long, contains :) doesn't need URL encoding.
u.delete('/me/device-tokens', async (c) => {
  const me = c.get('user');
  const body = await c.req.json<{ token?: string }>().catch(() => null);
  const token = body?.token?.trim();
  if (!token) throw new HTTPException(400, { message: 'token required' });
  await c.env.DB
    .prepare('DELETE FROM device_tokens WHERE token = ? AND user_id = ?')
    .bind(token, me.id)
    .run();
  return c.json({ ok: true });
});

u.get('/admin/allowlist', requireAdmin, async (c) => {
  const rows = await c.env.DB
    .prepare(`
      SELECT a.tenant_id, t.name AS tenant_name, a.email, a.added_at, a.used_at, a.used_by,
             u.username AS user_username, u.display_name AS user_display_name
      FROM allowlist a
      JOIN tenants t ON t.id = a.tenant_id
      LEFT JOIN users u ON u.id = a.used_by
      ORDER BY a.added_at DESC
    `)
    .all();
  return c.json({ items: rows.results ?? [] });
});

u.post('/admin/allowlist', requireAdmin, async (c) => {
  const me = c.get('user');
  const body = await c.req.json<{ email: string; tenant_id?: string }>().catch(() => null);
  const email = body?.email?.trim().toLowerCase();
  const tenantId = body?.tenant_id ?? DEFAULT_TENANT_ID;
  if (!email) throw new HTTPException(400, { message: 'email required' });
  if (!/^.+@.+\..+$/.test(email)) throw new HTTPException(400, { message: 'invalid email' });
  const tenant = await c.env.DB.prepare('SELECT id FROM tenants WHERE id = ?').bind(tenantId).first();
  if (!tenant) throw new HTTPException(404, { message: 'family not found' });
  // Inviting an email that already has an account adds the membership
  // directly — finalize only runs on first sign-in, so an allowlist row for
  // an existing user would never be redeemed.
  const existing = await c.env.DB
    .prepare('SELECT id FROM users WHERE email = ?')
    .bind(email)
    .first<{ id: string }>();
  if (existing) {
    await c.env.DB.batch([
      c.env.DB
        .prepare('INSERT OR IGNORE INTO tenant_members (tenant_id, user_id, role, created_at) VALUES (?, ?, ?, ?)')
        .bind(tenantId, existing.id, 'member', now()),
      c.env.DB
        .prepare('INSERT OR IGNORE INTO allowlist (tenant_id, email, added_by, added_at, used_by, used_at) VALUES (?, ?, ?, ?, ?, ?)')
        .bind(tenantId, email, me.id, now(), existing.id, now()),
    ]);
  } else {
    await c.env.DB
      .prepare('INSERT OR IGNORE INTO allowlist (tenant_id, email, added_by, added_at) VALUES (?, ?, ?, ?)')
      .bind(tenantId, email, me.id, now())
      .run();
  }
  return c.json({ email, tenant_id: tenantId });
});

u.delete('/admin/allowlist/:email', requireAdmin, async (c) => {
  const email = decodeURIComponent(c.req.param('email')).toLowerCase();
  const tenantId = c.req.query('tenant_id') ?? DEFAULT_TENANT_ID;
  await c.env.DB.prepare('DELETE FROM allowlist WHERE tenant_id = ? AND email = ?').bind(tenantId, email).run();
  return c.json({ ok: true });
});

u.get('/admin/users', requireAdmin, async (c) => {
  const rows = await c.env.DB
    .prepare(`
      SELECT u.id, u.email, u.username, u.display_name, u.avatar_key, u.is_admin, u.created_at,
             (SELECT GROUP_CONCAT(t.name, ', ') FROM tenant_members tm JOIN tenants t ON t.id = tm.tenant_id WHERE tm.user_id = u.id) AS tenant_names
      FROM users u
      WHERE u.is_demo = 0
      ORDER BY u.created_at DESC
    `)
    .all();
  const items = await Promise.all((rows.results ?? []).map((row) => decorateUser(c, row)));
  return c.json({ items });
});

u.get('/admin/tenants', requireAdmin, async (c) => {
  const rows = await c.env.DB
    .prepare(`
      SELECT t.id, t.name, t.created_at,
             (SELECT COUNT(*) FROM tenant_members tm WHERE tm.tenant_id = t.id) AS member_count
      FROM tenants t
      ORDER BY t.created_at ASC
    `)
    .all();
  return c.json({ items: rows.results ?? [] });
});

u.post('/admin/tenants', requireAdmin, async (c) => {
  const me = c.get('user');
  const body = await c.req.json<{ name?: string }>().catch(() => null);
  const name = body?.name?.trim();
  if (!name) throw new HTTPException(400, { message: 'name required' });
  const id = newId();
  const ts = now();
  // The creating admin joins immediately so the new family is manageable
  // (and visible in their switcher) right away.
  await c.env.DB.batch([
    c.env.DB.prepare('INSERT INTO tenants (id, name, created_at) VALUES (?, ?, ?)').bind(id, name.slice(0, 60), ts),
    c.env.DB
      .prepare('INSERT INTO tenant_members (tenant_id, user_id, role, created_at) VALUES (?, ?, ?, ?)')
      .bind(id, me.id, 'admin', ts),
  ]);
  return c.json({ id, name: name.slice(0, 60), created_at: ts, member_count: 1 }, 201);
});

u.patch('/admin/tenants/:id', requireAdmin, async (c) => {
  const id = c.req.param('id');
  const body = await c.req.json<{ name?: string }>().catch(() => null);
  const name = body?.name?.trim();
  if (!name) throw new HTTPException(400, { message: 'name required' });
  const res = await c.env.DB.prepare('UPDATE tenants SET name = ? WHERE id = ?').bind(name.slice(0, 60), id).run();
  if (!res.meta.changes) throw new HTTPException(404, { message: 'family not found' });
  return c.json({ ok: true });
});

u.get('/admin/tenants/:id/members', requireAdmin, async (c) => {
  const id = c.req.param('id');
  const rows = await c.env.DB
    .prepare(`
      SELECT u.id, u.username, u.display_name, u.avatar_key, tm.role, tm.created_at
      FROM tenant_members tm
      JOIN users u ON u.id = tm.user_id
      WHERE tm.tenant_id = ?
      ORDER BY tm.created_at ASC
    `)
    .bind(id)
    .all();
  const items = await Promise.all((rows.results ?? []).map((row) => decorateUser(c, row)));
  return c.json({ items });
});

u.post('/admin/tenants/:id/members', requireAdmin, async (c) => {
  const tenantId = c.req.param('id');
  const body = await c.req.json<{ user_id?: string }>().catch(() => null);
  if (!body?.user_id) throw new HTTPException(400, { message: 'user_id required' });
  const tenant = await c.env.DB.prepare('SELECT id FROM tenants WHERE id = ?').bind(tenantId).first();
  if (!tenant) throw new HTTPException(404, { message: 'family not found' });
  const target = await c.env.DB.prepare('SELECT id FROM users WHERE id = ? AND is_demo = 0').bind(body.user_id).first();
  if (!target) throw new HTTPException(404, { message: 'user not found' });
  await c.env.DB
    .prepare('INSERT OR IGNORE INTO tenant_members (tenant_id, user_id, role, created_at) VALUES (?, ?, ?, ?)')
    .bind(tenantId, body.user_id, 'member', now())
    .run();
  return c.json({ ok: true });
});

u.delete('/admin/tenants/:id/members/:userId', requireAdmin, async (c) => {
  const tenantId = c.req.param('id');
  const userId = c.req.param('userId');
  // Refuse to strand a user with zero memberships — remove the account
  // instead (DELETE /me covers that) or move them first.
  const count = await c.env.DB
    .prepare('SELECT COUNT(*) AS n FROM tenant_members WHERE user_id = ?')
    .bind(userId)
    .first<{ n: number }>();
  if ((count?.n ?? 0) <= 1) throw new HTTPException(400, { message: 'cannot remove a member from their only family' });
  await c.env.DB.prepare('DELETE FROM tenant_members WHERE tenant_id = ? AND user_id = ?').bind(tenantId, userId).run();
  return c.json({ ok: true });
});

u.patch('/admin/users/:id', requireAdmin, async (c) => {
  const me = c.get('user');
  const id = c.req.param('id');
  const body = await c.req.json<{ is_admin?: boolean }>().catch(() => null);
  if (!body || body.is_admin === undefined) throw new HTTPException(400, { message: 'is_admin required' });
  if (id === me.id && !body.is_admin) {
    throw new HTTPException(400, { message: 'cannot demote yourself' });
  }
  await c.env.DB
    .prepare('UPDATE users SET is_admin = ? WHERE id = ?')
    .bind(body.is_admin ? 1 : 0, id)
    .run();
  const row = await c.env.DB
    .prepare('SELECT id, email, username, display_name, avatar_key, is_admin, created_at FROM users WHERE id = ?')
    .bind(id)
    .first();
  if (!row) throw new HTTPException(404, { message: 'user not found' });
  return c.json(await decorateUser(c, row));
});

const PENDING_MEDIA_TTL_SEC = 24 * 60 * 60;

// Best-effort cleanup of a user's abandoned staged uploads. A multi-photo
// upload that never became a post (app killed, gave up mid-retry) leaves
// pending_media rows + R2 objects behind; sweep the user's >24h-old ones on
// their next upload so nothing leaks. Failures here never fail the request.
async function sweepPendingMedia(env: Env, userId: string): Promise<void> {
  try {
    const cutoff = now() - PENDING_MEDIA_TTL_SEC;
    const stale = await env.DB
      .prepare('SELECT id, image_key, thumb_key FROM pending_media WHERE user_id = ? AND created_at < ?')
      .bind(userId, cutoff)
      .all<{ id: string; image_key: string; thumb_key: string }>();
    const rows = stale.results ?? [];
    if (rows.length === 0) return;
    await Promise.all(rows.flatMap((r) => [
      env.MEDIA.delete(r.image_key).catch(() => {}),
      env.MEDIA.delete(r.thumb_key).catch(() => {}),
    ]));
    const ids = rows.map((r) => r.id);
    const placeholders = ids.map(() => '?').join(',');
    await env.DB.prepare(`DELETE FROM pending_media WHERE id IN (${placeholders})`).bind(...ids).run();
  } catch (e) {
    console.error('sweepPendingMedia failed', e);
  }
}

// Single-photo staged upload. Clients upload each photo here first, then call
// POST /posts (JSON) to assemble them by media_id into one post. Splitting the
// byte transfer per-photo — each request small — keeps a stalling uplink from
// killing a whole multi-photo post. See migration 0005.
u.post('/media', async (c) => {
  const me = c.get('user');
  // Non-blocking sweep of this user's abandoned (>24h) staged uploads.
  c.executionCtx.waitUntil(sweepPendingMedia(c.env, me.id));

  const form = await c.req.formData();
  const image = form.get('image') as File | string | null;
  if (!image || typeof image === 'string') throw new HTTPException(400, { message: 'image file required' });
  const thumb = form.get('thumb') as File | string | null;
  if (!thumb || typeof thumb === 'string') throw new HTTPException(400, { message: 'thumb file required' });
  if (image.size > 12 * 1024 * 1024) throw new HTTPException(413, { message: 'image > 12 MB' });
  if (thumb.size > 1024 * 1024) throw new HTTPException(413, { message: 'thumb > 1 MB' });
  if (!image.type.startsWith('image/')) throw new HTTPException(415, { message: 'image must be image/*' });

  const wStr = form.get('width') as string | null;
  const hStr = form.get('height') as string | null;
  const width = wStr ? Number(wStr) || null : null;
  const height = hStr ? Number(hStr) || null : null;

  const mediaId = newId();
  const imgExt = image.type === 'image/png' ? 'png' : image.type === 'image/webp' ? 'webp' : 'jpg';
  const thumbExt = thumb.type === 'image/webp' ? 'webp' : 'jpg';
  const imageKey = `posts/${me.id}/${mediaId}.${imgExt}`;
  const thumbKey = `posts/${me.id}/${mediaId}_thumb.${thumbExt}`;

  await Promise.all([
    c.env.MEDIA.put(imageKey, image.stream(), { httpMetadata: { contentType: image.type } }),
    c.env.MEDIA.put(thumbKey, thumb.stream(), { httpMetadata: { contentType: thumb.type } }),
  ]);

  await c.env.DB
    .prepare('INSERT INTO pending_media (id, user_id, image_key, thumb_key, width, height, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)')
    .bind(mediaId, me.id, imageKey, thumbKey, width, height, now())
    .run();

  return c.json({ media_id: mediaId });
});

// Assemble a post from photos already uploaded via POST /media. The post is
// created atomically with all its media in one batch, so a partial upload
// never yields a half-formed post. Consumed pending_media rows are deleted in
// the same batch.
async function createPostFromPendingMedia(c: Context<App>, me: AppUser): Promise<Response> {
  const body = await c.req.json<{ caption?: string; media_ids?: string[]; tenant_ids?: string[] }>().catch(() => null);
  const rawCaption = typeof body?.caption === 'string' ? body.caption.slice(0, 2000) : '';
  const caption = rawCaption.length ? rawCaption : null;
  const mediaIds = Array.isArray(body?.media_ids) ? body!.media_ids! : [];
  const cap = getMaxPostMedia(c.env);

  if (mediaIds.length === 0) throw new HTTPException(400, { message: 'at least one media_id required' });
  if (mediaIds.length > cap) throw new HTTPException(400, { message: `at most ${cap} photos per post` });
  if (new Set(mediaIds).size !== mediaIds.length) throw new HTTPException(400, { message: 'duplicate media_id' });

  // Audience: one post row per requested tenant, all sharing the same R2
  // keys. Each family keeps its own like/comment thread on its own row.
  const memberships = c.get('tenants');
  const tenantIds = [...new Set(Array.isArray(body?.tenant_ids) && body!.tenant_ids!.length > 0
    ? body!.tenant_ids!
    : [c.get('activeTenantId')])];
  for (const t of tenantIds) {
    if (!memberships.some((m) => m.tenant_id === t)) {
      throw new HTTPException(400, { message: 'not a member of this family' });
    }
  }

  const placeholders = mediaIds.map(() => '?').join(',');
  const pend = await c.env.DB
    .prepare(`SELECT id, image_key, thumb_key, width, height FROM pending_media WHERE user_id = ? AND id IN (${placeholders})`)
    .bind(me.id, ...mediaIds)
    .all<{ id: string; image_key: string; thumb_key: string; width: number | null; height: number | null }>();
  const byId = new Map((pend.results ?? []).map((r) => [r.id, r]));
  for (const id of mediaIds) {
    if (!byId.has(id)) throw new HTTPException(400, { message: `unknown or expired media_id: ${id}` });
  }

  // Preserve client-sent order as the carousel idx.
  const built = mediaIds.map((id, idx) => {
    const r = byId.get(id)!;
    return { idx, imageKey: r.image_key, thumbKey: r.thumb_key, width: r.width, height: r.height };
  });

  // One post row per audience tenant; sibling rows share the same R2 keys.
  const postIdByTenant = new Map<string, string>(tenantIds.map((t) => [t, newId()]));
  const ts = now();
  const stmts = [];
  for (const [tenantId, pid] of postIdByTenant) {
    stmts.push(
      c.env.DB
        .prepare('INSERT INTO posts (id, user_id, tenant_id, caption, created_at) VALUES (?, ?, ?, ?, ?)')
        .bind(pid, me.id, tenantId, caption, ts),
      ...built.map((b) =>
        c.env.DB
          .prepare('INSERT INTO post_media (post_id, idx, image_key, thumb_key, width, height) VALUES (?, ?, ?, ?, ?, ?)')
          .bind(pid, b.idx, b.imageKey, b.thumbKey, b.width, b.height),
      ),
    );
  }
  stmts.push(c.env.DB.prepare(`DELETE FROM pending_media WHERE user_id = ? AND id IN (${placeholders})`).bind(me.id, ...mediaIds));
  await c.env.DB.batch(stmts);

  c.executionCtx.waitUntil(fanOutNewPost(c.env, me, postIdByTenant, caption));

  // Return the row the client's current feed will show: the active tenant's
  // if it is in the audience, otherwise the first audience tenant's.
  const primaryId = postIdByTenant.get(c.get('activeTenantId')) ?? postIdByTenant.get(tenantIds[0]!)!;
  const sign = await signerFor(c);
  const media = await Promise.all(built.map(async (b) => ({
    idx: b.idx,
    image_url: await sign(b.imageKey),
    thumb_url: await sign(b.thumbKey),
    width: b.width,
    height: b.height,
  })));
  return c.json({ id: primaryId, created_at: ts, media });
}

u.post('/posts', async (c) => {
  const me = c.get('user');

  // New resilient path: photos were uploaded individually via POST /media and
  // are referenced here by id (small JSON request, never times out). The
  // legacy single-multipart path below stays for older installed app builds.
  if ((c.req.header('Content-Type') ?? '').includes('application/json')) {
    return createPostFromPendingMedia(c, me);
  }

  const form = await c.req.formData();
  const caption = (form.get('caption') as string | null)?.slice(0, 2000) ?? null;
  const cap = getMaxPostMedia(c.env);

  // Mobile uploads N photos with indexed form fields image_0..image_{N-1}.
  // Stop at the first missing image; everything after is ignored.
  type Part = { image: File; thumb: File; width: number | null; height: number | null };
  const parts: Part[] = [];
  for (let i = 0; i < cap; i++) {
    const image = form.get(`image_${i}`) as File | string | null;
    if (!image || typeof image === 'string') break;
    const thumb = form.get(`thumb_${i}`) as File | string | null;
    if (!thumb || typeof thumb === 'string') {
      throw new HTTPException(400, { message: `thumb_${i} file required` });
    }
    if (image.size > 12 * 1024 * 1024) throw new HTTPException(413, { message: `image_${i} > 12 MB` });
    if (thumb.size > 1024 * 1024) throw new HTTPException(413, { message: `thumb_${i} > 1 MB` });
    if (!image.type.startsWith('image/')) throw new HTTPException(415, { message: `image_${i} must be image/*` });
    const wStr = form.get(`width_${i}`) as string | null;
    const hStr = form.get(`height_${i}`) as string | null;
    parts.push({
      image,
      thumb,
      width: wStr ? Number(wStr) || null : null,
      height: hStr ? Number(hStr) || null : null,
    });
  }
  if (parts.length === 0) {
    // Single-photo legacy field names: accept them as image_0/thumb_0 if present.
    const image = form.get('image') as File | string | null;
    const thumb = form.get('thumb') as File | string | null;
    if (image && typeof image !== 'string' && thumb && typeof thumb !== 'string') {
      if (image.size > 12 * 1024 * 1024) throw new HTTPException(413, { message: 'image > 12 MB' });
      if (thumb.size > 1024 * 1024) throw new HTTPException(413, { message: 'thumb > 1 MB' });
      if (!image.type.startsWith('image/')) throw new HTTPException(415, { message: 'image must be image/*' });
      const wStr = form.get('width') as string | null;
      const hStr = form.get('height') as string | null;
      parts.push({
        image,
        thumb,
        width: wStr ? Number(wStr) || null : null,
        height: hStr ? Number(hStr) || null : null,
      });
    }
  }
  if (parts.length === 0) throw new HTTPException(400, { message: 'at least one image required' });

  const postId = newId();
  const built = parts.map((p, idx) => {
    const imgExt = p.image.type === 'image/png' ? 'png'
      : p.image.type === 'image/webp' ? 'webp'
      : 'jpg';
    const thumbExt = p.thumb.type === 'image/webp' ? 'webp' : 'jpg';
    return {
      idx,
      imageKey: `posts/${me.id}/${postId}_${idx}.${imgExt}`,
      thumbKey: `posts/${me.id}/${postId}_${idx}_thumb.${thumbExt}`,
      image: p.image,
      thumb: p.thumb,
      width: p.width,
      height: p.height,
    };
  });

  await Promise.all(built.flatMap((b) => [
    c.env.MEDIA.put(b.imageKey, b.image.stream(), { httpMetadata: { contentType: b.image.type } }),
    c.env.MEDIA.put(b.thumbKey, b.thumb.stream(), { httpMetadata: { contentType: b.thumb.type } }),
  ]));

  // Legacy multipart clients predate tenancy: single post in the active
  // (i.e. fallback first) tenant.
  const tenantId = c.get('activeTenantId');
  const ts = now();
  const stmts = [
    c.env.DB
      .prepare('INSERT INTO posts (id, user_id, tenant_id, caption, created_at) VALUES (?, ?, ?, ?, ?)')
      .bind(postId, me.id, tenantId, caption, ts),
    ...built.map((b) =>
      c.env.DB
        .prepare('INSERT INTO post_media (post_id, idx, image_key, thumb_key, width, height) VALUES (?, ?, ?, ?, ?, ?)')
        .bind(postId, b.idx, b.imageKey, b.thumbKey, b.width, b.height),
    ),
  ];
  await c.env.DB.batch(stmts);

  c.executionCtx.waitUntil(fanOutNewPost(c.env, me, new Map([[tenantId, postId]]), caption));

  const sign = await signerFor(c);
  const media = await Promise.all(built.map(async (b) => ({
    idx: b.idx,
    image_url: await sign(b.imageKey),
    thumb_url: await sign(b.thumbKey),
    width: b.width,
    height: b.height,
  })));
  return c.json({ id: postId, created_at: ts, media });
});

// Notify the members of every tenant the post went to, author excluded.
// @-mentions in the caption upgrade the mentioned user's push from the
// generic broadcast to a personalised "mentioned you in their post"
// notification — each recipient still gets at most one push, even when they
// belong to several audience tenants. Each recipient's payload carries the
// post row of a tenant THEY are in. waitUntil keeps the upload response
// fast; FCM failures don't fail the post. Invalid tokens are pruned so dead
// devices don't slow future fan-outs.
async function fanOutNewPost(
  env: Env,
  author: AppUser,
  postIdByTenant: Map<string, string>, // tenant_id -> that tenant's sibling post row
  caption: string | null,
): Promise<void> {
  // Demo identities (App Review accounts) shouldn't broadcast to the family.
  if (author.ory_id.startsWith('demo:')) {
    if (isDebugEnabled(env)) console.log(`push: skipping fan-out — demo author ${author.ory_id}`);
    return;
  }
  try {
    // Parse @mentions from the caption (same regex as the mobile autocomplete
    // and fanOutNewComment). Resolve to user_ids. Drop the author so a
    // self-mention in the caption is a no-op.
    const usernames = new Set<string>();
    if (caption) {
      const mentionRe = /@([a-z0-9_]+)/gi;
      let m: RegExpExecArray | null;
      while ((m = mentionRe.exec(caption)) !== null) {
        usernames.add(m[1]!.toLowerCase());
      }
    }
    const tenantIds = [...postIdByTenant.keys()];
    const tenantPh = tenantIds.map(() => '?').join(',');
    let mentionedIds = new Set<string>();
    if (usernames.size > 0) {
      const unames = Array.from(usernames);
      const placeholders = unames.map(() => '?').join(',');
      // Only members of the audience tenants can be mentioned — an @username
      // from another family must not leak a push (or the post) to them.
      const rows = await env.DB
        .prepare(`SELECT DISTINCT u.id FROM users u JOIN tenant_members tm ON tm.user_id = u.id WHERE u.username IN (${placeholders}) AND tm.tenant_id IN (${tenantPh})`)
        .bind(...unames, ...tenantIds)
        .all<{ id: string }>();
      mentionedIds = new Set((rows.results ?? []).map((r) => r.id));
      mentionedIds.delete(author.id);
    }

    // One query for all recipient tokens across the audience tenants. A
    // dual-tenant member appears once per tenant; the seen-set keeps it to
    // one push. Tokens bucket by (sibling post id, mentioned?) so every
    // recipient deep-links to a post row they can actually open.
    const tokRows = await env.DB
      .prepare(`SELECT dt.token, dt.user_id, tm.tenant_id FROM device_tokens dt JOIN tenant_members tm ON tm.user_id = dt.user_id WHERE tm.tenant_id IN (${tenantPh}) AND dt.user_id != ?`)
      .bind(...tenantIds, author.id)
      .all<{ token: string; user_id: string; tenant_id: string }>();
    const seenTokens = new Set<string>();
    const buckets = new Map<string, { broadcast: string[]; mentioned: string[] }>(); // key: tenant_id
    let total = 0;
    for (const r of tokRows.results ?? []) {
      if (seenTokens.has(r.token)) continue;
      seenTokens.add(r.token);
      let b = buckets.get(r.tenant_id);
      if (!b) {
        b = { broadcast: [], mentioned: [] };
        buckets.set(r.tenant_id, b);
      }
      (mentionedIds.has(r.user_id) ? b.mentioned : b.broadcast).push(r.token);
      total++;
    }
    if (isDebugEnabled(env)) {
      console.log(`push: fan-out posts=${[...postIdByTenant.values()].join(',')} author=${author.id} recipients=${total} mentions=${mentionedIds.size}`);
    }
    if (total === 0) return;

    const snippet = caption && caption.trim().length > 0 ? caption.slice(0, 140) : null;
    const invalidAll: string[] = [];

    for (const [tenantId, b] of buckets) {
      const postId = postIdByTenant.get(tenantId)!;
      if (b.broadcast.length > 0) {
        const { sent, invalidTokens } = await sendPush(env, b.broadcast, {
          title: author.display_name,
          body: snippet ?? 'shared a new photo',
          data: { post_id: postId, tenant_id: tenantId, type: 'new_post' },
        });
        if (isDebugEnabled(env)) console.log(`push: post broadcast tenant=${tenantId} sent=${sent} invalid=${invalidTokens.length}`);
        invalidAll.push(...invalidTokens);
      }
      if (b.mentioned.length > 0) {
        const { sent, invalidTokens } = await sendPush(env, b.mentioned, {
          title: author.display_name,
          body: 'mentioned you in their post',
          data: { post_id: postId, tenant_id: tenantId, type: 'mention' },
        });
        if (isDebugEnabled(env)) console.log(`push: post mention tenant=${tenantId} sent=${sent} invalid=${invalidTokens.length}`);
        invalidAll.push(...invalidTokens);
      }
    }

    if (invalidAll.length > 0) {
      const placeholders = invalidAll.map(() => '?').join(',');
      await env.DB
        .prepare(`DELETE FROM device_tokens WHERE token IN (${placeholders})`)
        .bind(...invalidAll)
        .run();
    }
  } catch (e) {
    console.error('fanOutNewPost failed', e);
  }
}

// Push the new comment to the post's author and to anyone @mentioned in the
// body, with copy that depends on whether the recipient is the author,
// mentioned, or both. Each recipient gets at most one push per comment.
// Same waitUntil / invalid-token pruning shape as fanOutNewPost.
async function fanOutNewComment(
  env: Env,
  commenter: AppUser,
  postId: string,
  commentId: string,
  commentText: string,
): Promise<void> {
  if (commenter.ory_id.startsWith('demo:')) {
    if (isDebugEnabled(env)) console.log(`push: skipping comment fan-out — demo commenter ${commenter.ory_id}`);
    return;
  }
  try {
    const post = await env.DB
      .prepare('SELECT user_id, tenant_id FROM posts WHERE id = ?')
      .bind(postId)
      .first<{ user_id: string; tenant_id: string }>();
    if (!post) return;

    // Mentions use [a-z0-9_] (same as the mobile autocomplete in
    // widgets/mention_field.dart). Case-insensitive so "@Allan" still
    // resolves; usernames in D1 are stored lowercase.
    const usernames = new Set<string>();
    const mentionRe = /@([a-z0-9_]+)/gi;
    let m: RegExpExecArray | null;
    while ((m = mentionRe.exec(commentText)) !== null) {
      usernames.add(m[1]!.toLowerCase());
    }

    let mentionedIds = new Set<string>();
    if (usernames.size > 0) {
      const unames = Array.from(usernames);
      const placeholders = unames.map(() => '?').join(',');
      // Scoped to the post's tenant so a same-named user in another family
      // never gets pushed a post they can't open.
      const rows = await env.DB
        .prepare(`SELECT u.id FROM users u JOIN tenant_members tm ON tm.user_id = u.id WHERE u.username IN (${placeholders}) AND tm.tenant_id = ?`)
        .bind(...unames, post.tenant_id)
        .all<{ id: string }>();
      mentionedIds = new Set((rows.results ?? []).map((r) => r.id));
    }

    // Bucket each recipient by message kind. The commenter is always
    // excluded; the post author and a mentioned-mentioned overlap is folded
    // into a single "both" message so nobody gets two pushes for one comment.
    const buckets: Record<'author_only' | 'mentioned_only' | 'both', Set<string>> = {
      author_only: new Set(),
      mentioned_only: new Set(),
      both: new Set(),
    };
    const authorIsCommenter = post.user_id === commenter.id;
    const authorIsMentioned = mentionedIds.has(post.user_id);

    if (!authorIsCommenter) {
      if (authorIsMentioned) buckets.both.add(post.user_id);
      else buckets.author_only.add(post.user_id);
    }
    for (const id of mentionedIds) {
      if (id === commenter.id) continue;
      if (id === post.user_id) continue; // already in author or both
      buckets.mentioned_only.add(id);
    }

    const totalRecipients = buckets.author_only.size + buckets.mentioned_only.size + buckets.both.size;
    if (isDebugEnabled(env)) {
      console.log(`push: fan-out comment=${commentId} post=${postId} commenter=${commenter.id} recipients=${totalRecipients} mentions=${mentionedIds.size}`);
    }
    if (totalRecipients === 0) return;

    const invalidAll: string[] = [];

    for (const kind of ['author_only', 'mentioned_only', 'both'] as const) {
      const ids = buckets[kind];
      if (ids.size === 0) continue;
      const idArr = Array.from(ids);
      const placeholders = idArr.map(() => '?').join(',');
      const tokRows = await env.DB
        .prepare(`SELECT token FROM device_tokens WHERE user_id IN (${placeholders})`)
        .bind(...idArr)
        .all<{ token: string }>();
      const tokens = (tokRows.results ?? []).map((r) => r.token);
      if (tokens.length === 0) continue;

      let body: string;
      let type: string;
      if (kind === 'author_only') {
        body = 'commented on your post';
        type = 'new_comment';
      } else if (kind === 'mentioned_only') {
        body = 'mentioned you in a comment';
        type = 'mention';
      } else {
        body = 'commented on your post and mentioned you';
        type = 'comment_with_mention';
      }
      const { sent, invalidTokens } = await sendPush(env, tokens, {
        title: commenter.display_name,
        body,
        data: { post_id: postId, comment_id: commentId, tenant_id: post.tenant_id, type },
      });
      if (isDebugEnabled(env)) console.log(`push: comment kind=${kind} sent=${sent} invalid=${invalidTokens.length}`);
      invalidAll.push(...invalidTokens);
    }

    if (invalidAll.length > 0) {
      const placeholders = invalidAll.map(() => '?').join(',');
      await env.DB
        .prepare(`DELETE FROM device_tokens WHERE token IN (${placeholders})`)
        .bind(...invalidAll)
        .run();
    }
  } catch (e) {
    console.error('fanOutNewComment failed', e);
  }
}

// Demo (App Review) and real users live in isolated worlds: a post is only
// visible to a viewer whose is_demo matches the post author's. Throws 404 (not
// 403) so a demo user can't probe for the existence of real posts. Use this on
// every per-post read/write that takes a :id from the client.
async function assertPostVisible(c: Context<App>, me: AppUser, postId: string): Promise<void> {
  // Visible if the post lives in ANY tenant the caller belongs to (not just
  // the active one) — push deep-links may open a post from the other family
  // before the client has switched.
  const row = await c.env.DB
    .prepare('SELECT 1 AS ok FROM posts p WHERE p.id = ? AND p.tenant_id IN (SELECT tenant_id FROM tenant_members WHERE user_id = ?)')
    .bind(postId, me.id)
    .first();
  if (!row) throw new HTTPException(404, { message: 'post not found' });
}

// Cursor is the created_at of the last seen item.
u.get('/feed', async (c) => {
  const me = c.get('user');
  const limit = Math.min(Number(c.req.query('limit') ?? 20), 50);
  const cursor = c.req.query('cursor');
  const cursorTs = cursor ? Number(cursor) : Number.MAX_SAFE_INTEGER;

  const rows = await c.env.DB
    .prepare(`
      SELECT
        p.id, p.user_id, p.tenant_id, p.caption, p.created_at,
        u.username, u.display_name, u.avatar_key,
        (SELECT COUNT(*) FROM likes l WHERE l.post_id = p.id) AS like_count,
        (SELECT COUNT(*) FROM comments cm WHERE cm.post_id = p.id) AS comment_count,
        EXISTS(SELECT 1 FROM likes l2 WHERE l2.post_id = p.id AND l2.user_id = ?) AS liked
      FROM posts p
      JOIN users u ON u.id = p.user_id
      WHERE p.tenant_id = ? AND p.created_at < ?
      ORDER BY p.created_at DESC
      LIMIT ?
    `)
    .bind(me.id, c.get('activeTenantId'), cursorTs, limit)
    .all();

  const postRows = rows.results ?? [];
  const mediaByPost = await fetchMediaForPosts(c, postRows.map((r) => r.id as string));
  const items = await Promise.all(postRows.map((row) => decoratePost(c, row, mediaByPost.get(row.id as string) ?? [])));
  const nextCursor = items.length === limit ? String(items[items.length - 1]!.created_at) : null;
  return c.json({ items, next_cursor: nextCursor });
});

// Literal-path routes must come before parametric /users/:id so "search" etc.
// aren't treated as a user id.
u.get('/users/search', async (c) => {
  const me = c.get('user');
  const q = (c.req.query('q') ?? '').trim().toLowerCase();
  if (q.length === 0) return c.json({ items: [] });
  const like = `${q.replace(/[%_]/g, '\\$&')}%`;
  const rows = await c.env.DB
    .prepare(`
      SELECT id, username, display_name, avatar_key
      FROM users
      WHERE (LOWER(username) LIKE ? ESCAPE '\\'
         OR LOWER(display_name) LIKE ? ESCAPE '\\')
        AND id IN (SELECT user_id FROM tenant_members WHERE tenant_id = ?)
      ORDER BY username ASC
      LIMIT 8
    `)
    .bind(like, like, c.get('activeTenantId'))
    .all();
  const items = await Promise.all((rows.results ?? []).map((row) => decorateUser(c, row)));
  return c.json({ items });
});

u.get('/users/by-username/:username', async (c) => {
  const me = c.get('user');
  const row = await c.env.DB
    .prepare('SELECT id, email, username, display_name, avatar_key, is_admin, created_at FROM users WHERE username = ? AND id IN (SELECT tm.user_id FROM tenant_members tm JOIN tenant_members mine ON mine.tenant_id = tm.tenant_id WHERE mine.user_id = ?)')
    .bind(c.req.param('username').toLowerCase(), me.id)
    .first();
  if (!row) throw new HTTPException(404, { message: 'user not found' });
  return c.json(await decorateUser(c, row));
});

u.get('/users/:id', async (c) => {
  const me = c.get('user');
  const row = await c.env.DB
    .prepare('SELECT id, email, username, display_name, avatar_key, is_admin, created_at FROM users WHERE id = ? AND id IN (SELECT tm.user_id FROM tenant_members tm JOIN tenant_members mine ON mine.tenant_id = tm.tenant_id WHERE mine.user_id = ?)')
    .bind(c.req.param('id'), me.id)
    .first();
  if (!row) throw new HTTPException(404, { message: 'user not found' });
  return c.json(await decorateUser(c, row));
});

u.get('/users/:id/posts', async (c) => {
  const me = c.get('user');
  const userId = c.req.param('id');
  const limit = Math.min(Number(c.req.query('limit') ?? 30), 60);
  const cursor = c.req.query('cursor');
  const cursorTs = cursor ? Number(cursor) : Number.MAX_SAFE_INTEGER;
  const rows = await c.env.DB
    .prepare(`
      SELECT p.id, p.created_at,
             pm.image_key, pm.thumb_key, pm.width, pm.height,
             (SELECT COUNT(*) FROM post_media WHERE post_id = p.id) AS media_count
      FROM posts p
      LEFT JOIN post_media pm ON pm.post_id = p.id AND pm.idx = 0
      WHERE p.user_id = ? AND p.tenant_id = ? AND p.created_at < ?
      ORDER BY p.created_at DESC
      LIMIT ?
    `)
    .bind(userId, c.get('activeTenantId'), cursorTs, limit)
    .all();
  const rawItems = rows.results ?? [];
  const items = await Promise.all(rawItems.map((row) => decorateThumb(c, row)));
  const last = rawItems.length === limit ? rawItems[rawItems.length - 1] as { created_at: number } : null;
  return c.json({ items, next_cursor: last ? String(last.created_at) : null });
});

u.get('/posts/:id', async (c) => {
  const me = c.get('user');
  const id = c.req.param('id');
  const row = await c.env.DB
    .prepare(`
      SELECT p.id, p.user_id, p.tenant_id, p.caption, p.created_at,
             u.username, u.display_name, u.avatar_key,
             (SELECT COUNT(*) FROM likes l WHERE l.post_id = p.id) AS like_count,
             (SELECT COUNT(*) FROM comments cm WHERE cm.post_id = p.id) AS comment_count,
             EXISTS(SELECT 1 FROM likes l2 WHERE l2.post_id = p.id AND l2.user_id = ?) AS liked
      FROM posts p JOIN users u ON u.id = p.user_id
      WHERE p.id = ? AND p.tenant_id IN (SELECT tenant_id FROM tenant_members WHERE user_id = ?)
    `)
    .bind(me.id, id, me.id)
    .first();
  if (!row) throw new HTTPException(404, { message: 'post not found' });
  const mediaByPost = await fetchMediaForPosts(c, [id]);
  return c.json(await decoratePost(c, row, mediaByPost.get(id) ?? []));
});

u.delete('/posts/:id', async (c) => {
  const me = c.get('user');
  const id = c.req.param('id');
  const row = await c.env.DB.prepare('SELECT user_id FROM posts WHERE id = ?').bind(id).first<{ user_id: string }>();
  if (!row) throw new HTTPException(404, { message: 'post not found' });
  if (row.user_id !== me.id) throw new HTTPException(403, { message: 'not your post' });
  const media = await c.env.DB
    .prepare('SELECT image_key, thumb_key FROM post_media WHERE post_id = ?')
    .bind(id)
    .all<{ image_key: string; thumb_key: string }>();
  const r2Keys: string[] = [];
  for (const m of media.results ?? []) r2Keys.push(m.image_key, m.thumb_key);
  await c.env.DB.prepare('DELETE FROM posts WHERE id = ?').bind(id).run();
  // A "post to both families" sibling row shares these R2 keys — only delete
  // objects no remaining post_media row references. Runs after the DELETE
  // above so this post's own (cascaded) rows don't count as references.
  let orphanedKeys = r2Keys;
  if (r2Keys.length > 0) {
    const ph = r2Keys.map(() => '?').join(',');
    const stillUsed = await c.env.DB
      .prepare(`SELECT image_key, thumb_key FROM post_media WHERE image_key IN (${ph}) OR thumb_key IN (${ph})`)
      .bind(...r2Keys, ...r2Keys)
      .all<{ image_key: string; thumb_key: string }>();
    const used = new Set<string>();
    for (const m of stillUsed.results ?? []) {
      used.add(m.image_key);
      used.add(m.thumb_key);
    }
    orphanedKeys = r2Keys.filter((k) => !used.has(k));
  }
  c.executionCtx.waitUntil(Promise.all(orphanedKeys.map((k) => c.env.MEDIA.delete(k).catch(() => {}))).then(() => {}));
  return c.json({ ok: true });
});

u.post('/posts/:id/like', async (c) => {
  const me = c.get('user');
  const id = c.req.param('id');
  await assertPostVisible(c, me, id);
  await c.env.DB
    .prepare('INSERT OR IGNORE INTO likes (post_id, user_id, created_at) VALUES (?, ?, ?)')
    .bind(id, me.id, now())
    .run();
  return c.json({ ok: true });
});

u.delete('/posts/:id/like', async (c) => {
  const me = c.get('user');
  const id = c.req.param('id');
  await assertPostVisible(c, me, id);
  await c.env.DB.prepare('DELETE FROM likes WHERE post_id = ? AND user_id = ?').bind(id, me.id).run();
  return c.json({ ok: true });
});

// Who liked this post, newest first. Used by the long-press-on-heart bottom
// sheet in the mobile client. Capped at 200 — at family scale this is "all
// of them"; if a viral post ever shows up we can paginate.
u.get('/posts/:id/likes', async (c) => {
  const me = c.get('user');
  const id = c.req.param('id');
  await assertPostVisible(c, me, id);
  const rows = await c.env.DB
    .prepare(`
      SELECT u.id, u.username, u.display_name, u.avatar_key, l.created_at
      FROM likes l JOIN users u ON u.id = l.user_id
      WHERE l.post_id = ?
      ORDER BY l.created_at DESC
      LIMIT 200
    `)
    .bind(id)
    .all();
  const items = await Promise.all((rows.results ?? []).map((row) => decorateUser(c, row)));
  return c.json({ items });
});

u.get('/posts/:id/comments', async (c) => {
  const me = c.get('user');
  const id = c.req.param('id');
  await assertPostVisible(c, me, id);
  const rows = await c.env.DB
    .prepare(`
      SELECT cm.id, cm.body, cm.created_at, cm.user_id,
             u.username, u.display_name, u.avatar_key
      FROM comments cm JOIN users u ON u.id = cm.user_id
      WHERE cm.post_id = ?
      ORDER BY cm.created_at ASC
      LIMIT 200
    `)
    .bind(id)
    .all();
  const items = await Promise.all((rows.results ?? []).map((row) => decorateComment(c, row)));
  return c.json({ items });
});

u.post('/posts/:id/comments', async (c) => {
  const me = c.get('user');
  const id = c.req.param('id');
  const body = await c.req.json<{ body: string }>().catch(() => null);
  const text = body?.body?.trim();
  if (!text) throw new HTTPException(400, { message: 'body required' });
  if (text.length > 1000) throw new HTTPException(400, { message: 'comment too long' });
  await assertPostVisible(c, me, id);
  const commentId = newId();
  const ts = now();
  await c.env.DB
    .prepare('INSERT INTO comments (id, post_id, user_id, body, created_at) VALUES (?, ?, ?, ?, ?)')
    .bind(commentId, id, me.id, text, ts)
    .run();
  c.executionCtx.waitUntil(fanOutNewComment(c.env, me, id, commentId, text));
  return c.json(await decorateComment(c, {
    id: commentId,
    post_id: id,
    user_id: me.id,
    body: text,
    created_at: ts,
    username: me.username,
    display_name: me.display_name,
    avatar_key: me.avatar_key,
  }));
});

u.delete('/comments/:id', async (c) => {
  const me = c.get('user');
  const id = c.req.param('id');
  const row = await c.env.DB.prepare('SELECT user_id FROM comments WHERE id = ?').bind(id).first<{ user_id: string }>();
  if (!row) throw new HTTPException(404, { message: 'not found' });
  if (row.user_id !== me.id) throw new HTTPException(403, { message: 'not your comment' });
  await c.env.DB.prepare('DELETE FROM comments WHERE id = ?').bind(id).run();
  return c.json({ ok: true });
});

authed.route('/', u);
app.route('/', authed);

export default app;

async function signerFor(c: Context<App>) {
  const base = new URL(c.req.url).origin;
  return (key: string | null | undefined) =>
    key ? signMediaUrl(c.env, key, base) : Promise.resolve<string | null>(null);
}

type MediaRow = {
  post_id: string;
  idx: number;
  image_key: string;
  thumb_key: string;
  width: number | null;
  height: number | null;
};

async function fetchMediaForPosts(c: Context<App>, postIds: string[]): Promise<Map<string, MediaRow[]>> {
  const byPost = new Map<string, MediaRow[]>();
  if (postIds.length === 0) return byPost;
  const placeholders = postIds.map(() => '?').join(',');
  const rows = await c.env.DB
    .prepare(`
      SELECT post_id, idx, image_key, thumb_key, width, height
      FROM post_media
      WHERE post_id IN (${placeholders})
      ORDER BY post_id, idx
    `)
    .bind(...postIds)
    .all<MediaRow>();
  for (const m of rows.results ?? []) {
    const list = byPost.get(m.post_id) ?? [];
    list.push(m);
    byPost.set(m.post_id, list);
  }
  return byPost;
}

async function decoratePost(c: Context<App>, row: Record<string, unknown>, media: MediaRow[]) {
  const sign = await signerFor(c);
  const avatarUrl = await sign(row.avatar_key as string | null);
  const decoratedMedia = await Promise.all(media.map(async (m) => ({
    idx: m.idx,
    image_url: await sign(m.image_key),
    thumb_url: await sign(m.thumb_key),
    width: m.width,
    height: m.height,
  })));
  // Backward-compat for mobile clients shipped before the multi-photo
  // migration: those still read top-level image_url / thumb_url / width /
  // height. Mirror media[0] here so they keep working. Safe to drop once
  // every install in the wild is at-or-past the multi-photo build.
  const first = decoratedMedia[0];
  return {
    id: row.id,
    user_id: row.user_id,
    tenant_id: row.tenant_id ?? null,
    media: decoratedMedia,
    image_url: first?.image_url ?? null,
    thumb_url: first?.thumb_url ?? null,
    width: first?.width ?? null,
    height: first?.height ?? null,
    caption: row.caption,
    created_at: row.created_at,
    author: {
      id: row.user_id,
      username: row.username,
      display_name: row.display_name,
      avatar_url: avatarUrl,
    },
    like_count: Number(row.like_count ?? 0),
    comment_count: Number(row.comment_count ?? 0),
    liked: Boolean(row.liked),
  };
}

async function decorateUser(c: Context<App>, row: Record<string, unknown>) {
  const sign = await signerFor(c);
  const avatarUrl = await sign(row.avatar_key as string | null);
  const { avatar_key: _ignored, ...rest } = row;
  return { ...rest, avatar_url: avatarUrl };
}

async function decorateComment(c: Context<App>, row: Record<string, unknown>) {
  const sign = await signerFor(c);
  const avatarUrl = await sign(row.avatar_key as string | null);
  const { avatar_key: _ignored, ...rest } = row;
  return { ...rest, avatar_url: avatarUrl };
}

async function decorateThumb(c: Context<App>, row: Record<string, unknown>) {
  const sign = await signerFor(c);
  const [imageUrl, thumbUrl] = await Promise.all([
    sign(row.image_key as string | null),
    sign(row.thumb_key as string | null),
  ]);
  return {
    id: row.id,
    image_url: imageUrl,
    thumb_url: thumbUrl,
    width: row.width,
    height: row.height,
    media_count: Number(row.media_count ?? 1),
    created_at: row.created_at,
  };
}
