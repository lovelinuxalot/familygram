import { Hono } from 'hono';
import type { Context } from 'hono';
import { cors } from 'hono/cors';
import { logger } from 'hono/logger';
import { HTTPException } from 'hono/http-exception';

import type { Env, Variables } from './types';
import { isBootstrapAdmin } from './types';
import { oryAuth, requireAdmin, requireUser, isDemoModeEnabled, mintDemoToken, parseDemoUsers } from './auth';
import { signMediaUrl, verifyMediaSignature } from './media';
import { newId, now, slugifyEmailToUsername } from './util';
import privacyHtml from './pages/privacy.html';
import supportHtml from './pages/support.html';

type App = { Bindings: Env; Variables: Variables };

const app = new Hono<App>();

app.use('*', logger());

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

app.get('/config', (c) => c.json({ demo_mode: isDemoModeEnabled(c.env) }));

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
    .prepare('SELECT id, ory_id, email, username, display_name, avatar_key, is_admin, created_at FROM users WHERE ory_id = ?')
    .bind(ory.id)
    .first<{ id: string; ory_id: string; email: string; username: string; display_name: string; avatar_key: string | null; is_admin: number; created_at: number }>();
  if (existing) return c.json(await decorateUser(c, existing));

  const isDemo = c.get('isDemo');
  const isAdmin = isBootstrapAdmin(c.env, email);
  let allowed = isAdmin || isDemo;
  if (!allowed) {
    const entry = await c.env.DB
      .prepare('SELECT email, used_by FROM allowlist WHERE email = ?')
      .bind(email)
      .first<{ email: string; used_by: string | null }>();
    allowed = !!entry && !entry.used_by;
  }
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
      .prepare('INSERT INTO users (id, ory_id, email, username, display_name, avatar_key, is_admin, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)')
      .bind(userId, ory.id, email, username, display_name, avatarKey, isAdmin ? 1 : 0, ts),
    c.env.DB
      .prepare('UPDATE allowlist SET used_by = ?, used_at = ? WHERE email = ? AND used_by IS NULL')
      .bind(userId, ts, email),
  ]);

  return c.json(await decorateUser(c, {
    id: userId, ory_id: ory.id, email, username, display_name,
    avatar_key: avatarKey, is_admin: isAdmin ? 1 : 0, created_at: ts,
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

u.get('/me', async (c) => c.json(await decorateUser(c, c.get('user') as unknown as Record<string, unknown>)));

// Wipes posts, comments, likes, allowlist row, and user row. Best-effort R2 cleanup.
// Does NOT delete the Ory identity (= the user's Google account, out of our control).
u.delete('/me', async (c) => {
  const me = c.get('user');

  const ownPosts = await c.env.DB
    .prepare('SELECT image_key, thumb_key FROM posts WHERE user_id = ?')
    .bind(me.id)
    .all<{ image_key: string; thumb_key: string }>();
  const r2Keys: string[] = [];
  for (const p of ownPosts.results ?? []) {
    r2Keys.push(p.image_key, p.thumb_key);
  }
  if (me.avatar_key) r2Keys.push(me.avatar_key);

  await c.env.DB.batch([
    c.env.DB.prepare('DELETE FROM likes WHERE user_id = ?').bind(me.id),
    c.env.DB.prepare('DELETE FROM comments WHERE user_id = ?').bind(me.id),
    c.env.DB.prepare('DELETE FROM posts WHERE user_id = ?').bind(me.id),
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

u.get('/admin/allowlist', requireAdmin, async (c) => {
  const rows = await c.env.DB
    .prepare(`
      SELECT a.email, a.added_at, a.used_at, a.used_by,
             u.username AS user_username, u.display_name AS user_display_name
      FROM allowlist a
      LEFT JOIN users u ON u.id = a.used_by
      ORDER BY a.added_at DESC
    `)
    .all();
  return c.json({ items: rows.results ?? [] });
});

u.post('/admin/allowlist', requireAdmin, async (c) => {
  const me = c.get('user');
  const body = await c.req.json<{ email: string }>().catch(() => null);
  const email = body?.email?.trim().toLowerCase();
  if (!email) throw new HTTPException(400, { message: 'email required' });
  if (!/^.+@.+\..+$/.test(email)) throw new HTTPException(400, { message: 'invalid email' });
  await c.env.DB
    .prepare('INSERT OR IGNORE INTO allowlist (email, added_by, added_at) VALUES (?, ?, ?)')
    .bind(email, me.id, now())
    .run();
  return c.json({ email });
});

u.delete('/admin/allowlist/:email', requireAdmin, async (c) => {
  const email = decodeURIComponent(c.req.param('email')).toLowerCase();
  await c.env.DB.prepare('DELETE FROM allowlist WHERE email = ?').bind(email).run();
  return c.json({ ok: true });
});

u.get('/admin/users', requireAdmin, async (c) => {
  const rows = await c.env.DB
    .prepare('SELECT id, email, username, display_name, avatar_key, is_admin, created_at FROM users ORDER BY created_at DESC')
    .all();
  const items = await Promise.all((rows.results ?? []).map((row) => decorateUser(c, row)));
  return c.json({ items });
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

u.post('/posts', async (c) => {
  const me = c.get('user');
  const form = await c.req.formData();
  const image = form.get('image') as File | string | null;
  const thumb = form.get('thumb') as File | string | null;
  const caption = (form.get('caption') as string | null)?.slice(0, 2000) ?? null;
  const widthStr = form.get('width') as string | null;
  const heightStr = form.get('height') as string | null;

  if (!image || typeof image === 'string') throw new HTTPException(400, { message: 'image file required' });
  if (!thumb || typeof thumb === 'string') throw new HTTPException(400, { message: 'thumb file required' });
  if (image.size > 12 * 1024 * 1024) throw new HTTPException(413, { message: 'image > 12 MB' });
  if (thumb.size > 1024 * 1024) throw new HTTPException(413, { message: 'thumb > 1 MB' });
  if (!image.type.startsWith('image/')) throw new HTTPException(415, { message: 'image must be image/*' });

  const postId = newId();
  const imgExt = image.type === 'image/png' ? 'png' : 'jpg';
  const imageKey = `posts/${me.id}/${postId}.${imgExt}`;
  const thumbKey = `posts/${me.id}/${postId}_thumb.jpg`;

  await Promise.all([
    c.env.MEDIA.put(imageKey, image.stream(), { httpMetadata: { contentType: image.type } }),
    c.env.MEDIA.put(thumbKey, thumb.stream(), { httpMetadata: { contentType: 'image/jpeg' } }),
  ]);

  const width = widthStr ? Number(widthStr) || null : null;
  const height = heightStr ? Number(heightStr) || null : null;
  const ts = now();
  await c.env.DB
    .prepare('INSERT INTO posts (id, user_id, image_key, thumb_key, caption, width, height, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)')
    .bind(postId, me.id, imageKey, thumbKey, caption, width, height, ts)
    .run();

  const sign = await signerFor(c);
  return c.json({
    id: postId,
    image_url: await sign(imageKey),
    thumb_url: await sign(thumbKey),
    created_at: ts,
  });
});

// Cursor is the created_at of the last seen item.
u.get('/feed', async (c) => {
  const me = c.get('user');
  const limit = Math.min(Number(c.req.query('limit') ?? 20), 50);
  const cursor = c.req.query('cursor');
  const cursorTs = cursor ? Number(cursor) : Number.MAX_SAFE_INTEGER;

  const rows = await c.env.DB
    .prepare(`
      SELECT
        p.id, p.user_id, p.image_key, p.thumb_key, p.caption, p.width, p.height, p.created_at,
        u.username, u.display_name, u.avatar_key,
        (SELECT COUNT(*) FROM likes l WHERE l.post_id = p.id) AS like_count,
        (SELECT COUNT(*) FROM comments cm WHERE cm.post_id = p.id) AS comment_count,
        EXISTS(SELECT 1 FROM likes l2 WHERE l2.post_id = p.id AND l2.user_id = ?) AS liked
      FROM posts p
      JOIN users u ON u.id = p.user_id
      WHERE p.created_at < ?
      ORDER BY p.created_at DESC
      LIMIT ?
    `)
    .bind(me.id, cursorTs, limit)
    .all();

  const items = await Promise.all((rows.results ?? []).map((row) => decoratePost(c, row)));
  const nextCursor = items.length === limit ? String(items[items.length - 1]!.created_at) : null;
  return c.json({ items, next_cursor: nextCursor });
});

// Literal-path routes must come before parametric /users/:id so "search" etc.
// aren't treated as a user id.
u.get('/users/search', async (c) => {
  const q = (c.req.query('q') ?? '').trim().toLowerCase();
  if (q.length === 0) return c.json({ items: [] });
  const like = `${q.replace(/[%_]/g, '\\$&')}%`;
  const rows = await c.env.DB
    .prepare(`
      SELECT id, username, display_name, avatar_key
      FROM users
      WHERE LOWER(username) LIKE ? ESCAPE '\\'
         OR LOWER(display_name) LIKE ? ESCAPE '\\'
      ORDER BY username ASC
      LIMIT 8
    `)
    .bind(like, like)
    .all();
  const items = await Promise.all((rows.results ?? []).map((row) => decorateUser(c, row)));
  return c.json({ items });
});

u.get('/users/by-username/:username', async (c) => {
  const row = await c.env.DB
    .prepare('SELECT id, email, username, display_name, avatar_key, is_admin, created_at FROM users WHERE username = ?')
    .bind(c.req.param('username').toLowerCase())
    .first();
  if (!row) throw new HTTPException(404, { message: 'user not found' });
  return c.json(await decorateUser(c, row));
});

u.get('/users/:id', async (c) => {
  const row = await c.env.DB
    .prepare('SELECT id, email, username, display_name, avatar_key, is_admin, created_at FROM users WHERE id = ?')
    .bind(c.req.param('id'))
    .first();
  if (!row) throw new HTTPException(404, { message: 'user not found' });
  return c.json(await decorateUser(c, row));
});

u.get('/users/:id/posts', async (c) => {
  const userId = c.req.param('id');
  const limit = Math.min(Number(c.req.query('limit') ?? 30), 60);
  const cursor = c.req.query('cursor');
  const cursorTs = cursor ? Number(cursor) : Number.MAX_SAFE_INTEGER;
  const rows = await c.env.DB
    .prepare(`
      SELECT id, image_key, thumb_key, width, height, created_at
      FROM posts
      WHERE user_id = ? AND created_at < ?
      ORDER BY created_at DESC
      LIMIT ?
    `)
    .bind(userId, cursorTs, limit)
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
      SELECT p.id, p.user_id, p.image_key, p.thumb_key, p.caption, p.width, p.height, p.created_at,
             u.username, u.display_name, u.avatar_key,
             (SELECT COUNT(*) FROM likes l WHERE l.post_id = p.id) AS like_count,
             (SELECT COUNT(*) FROM comments cm WHERE cm.post_id = p.id) AS comment_count,
             EXISTS(SELECT 1 FROM likes l2 WHERE l2.post_id = p.id AND l2.user_id = ?) AS liked
      FROM posts p JOIN users u ON u.id = p.user_id
      WHERE p.id = ?
    `)
    .bind(me.id, id)
    .first();
  if (!row) throw new HTTPException(404, { message: 'post not found' });
  return c.json(await decoratePost(c, row));
});

u.delete('/posts/:id', async (c) => {
  const me = c.get('user');
  const id = c.req.param('id');
  const row = await c.env.DB.prepare('SELECT user_id, image_key, thumb_key FROM posts WHERE id = ?').bind(id).first<{ user_id: string; image_key: string; thumb_key: string }>();
  if (!row) throw new HTTPException(404, { message: 'post not found' });
  if (row.user_id !== me.id) throw new HTTPException(403, { message: 'not your post' });
  await c.env.DB.prepare('DELETE FROM posts WHERE id = ?').bind(id).run();
  c.executionCtx.waitUntil(Promise.all([c.env.MEDIA.delete(row.image_key), c.env.MEDIA.delete(row.thumb_key)]).then(() => {}));
  return c.json({ ok: true });
});

u.post('/posts/:id/like', async (c) => {
  const me = c.get('user');
  const id = c.req.param('id');
  await c.env.DB
    .prepare('INSERT OR IGNORE INTO likes (post_id, user_id, created_at) VALUES (?, ?, ?)')
    .bind(id, me.id, now())
    .run();
  return c.json({ ok: true });
});

u.delete('/posts/:id/like', async (c) => {
  const me = c.get('user');
  const id = c.req.param('id');
  await c.env.DB.prepare('DELETE FROM likes WHERE post_id = ? AND user_id = ?').bind(id, me.id).run();
  return c.json({ ok: true });
});

u.get('/posts/:id/comments', async (c) => {
  const id = c.req.param('id');
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
  const exists = await c.env.DB.prepare('SELECT id FROM posts WHERE id = ?').bind(id).first();
  if (!exists) throw new HTTPException(404, { message: 'post not found' });
  const commentId = newId();
  const ts = now();
  await c.env.DB
    .prepare('INSERT INTO comments (id, post_id, user_id, body, created_at) VALUES (?, ?, ?, ?, ?)')
    .bind(commentId, id, me.id, text, ts)
    .run();
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

async function decoratePost(c: Context<App>, row: Record<string, unknown>) {
  const sign = await signerFor(c);
  const [imageUrl, thumbUrl, avatarUrl] = await Promise.all([
    sign(row.image_key as string),
    sign(row.thumb_key as string),
    sign(row.avatar_key as string | null),
  ]);
  return {
    id: row.id,
    user_id: row.user_id,
    image_url: imageUrl,
    thumb_url: thumbUrl,
    caption: row.caption,
    width: row.width,
    height: row.height,
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
    sign(row.image_key as string),
    sign(row.thumb_key as string),
  ]);
  return {
    id: row.id,
    image_url: imageUrl,
    thumb_url: thumbUrl,
    width: row.width,
    height: row.height,
    created_at: row.created_at,
  };
}
