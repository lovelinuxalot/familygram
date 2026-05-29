export interface Env {
  DB: D1Database;
  MEDIA: R2Bucket;
  ORY_SDK_URL: string;
  MEDIA_PUBLIC_BASE: string;
  // Comma-separated browser origins permitted to call this API cross-origin.
  // Mobile (iOS/Android native) clients don't send an Origin header so are
  // unaffected. Empty / unset → deny all browser CORS requests.
  CORS_ORIGINS?: string;
  // Contact email rendered as a `mailto:` link on the public /support page.
  // Apple / Google review want a real support contact, so set this in your
  // wrangler.local.jsonc (e.g. "you@example.com"). Unset → /support shows a
  // generic "ask the admin who installed Familygram" message instead.
  SUPPORT_EMAIL?: string;
  // Per-IP rate limiter binding. Optional so local dev (without the binding
  // configured) still runs.
  RATE_LIMITER?: RateLimit;
  // Comma-separated emails granted admin on first request (e.g. "you@x.com,me@y.com").
  // Anyone in this list is auto-allowlisted AND auto-promoted to admin.
  ADMIN_EMAILS?: string;
  // HMAC secret for signing /media URLs. Set via:
  //   wrangler secret put MEDIA_SIGNING_SECRET
  // generate a strong value: `openssl rand -hex 32`
  MEDIA_SIGNING_SECRET?: string;
  // Demo-mode credentials. Comma-separated email:password pairs, e.g.
  //   "review@apple.com:hunter2,demo@x.com:abc123".
  // When non-empty, /auth/demo accepts these credentials and mints a locally-
  // signed token that bypasses Ory and the allowlist. Leave unset/empty to
  // disable demo mode entirely — /auth/demo then returns 404 and the mobile
  // UI hides the email/password form.
  DEMO_USERS?: string;
  // Firebase Cloud Messaging credentials for push notifications. Set via:
  //   wrangler secret put FCM_SERVICE_ACCOUNT_JSON   # paste full SA JSON
  //   wrangler secret put FCM_PROJECT_ID             # the project_id field
  // When either is unset, push fan-out silently no-ops (the rest of the app
  // still works). See docs/PUSH_NOTIFICATIONS.md for the Firebase setup.
  FCM_SERVICE_ACCOUNT_JSON?: string;
  FCM_PROJECT_ID?: string;
  // Verbose debug logging toggle. When set to a truthy value (1/true/yes/on),
  // the request logger middleware, push fan-out details, and /me/push-diagnostic
  // payloads are written to console — visible via `wrangler tail`. Toggle live
  // with no redeploy:
  //   enable:  echo 1 | npx wrangler secret put DEBUG_LOGGING -c wrangler.local.jsonc
  //   disable: npx wrangler secret delete DEBUG_LOGGING -c wrangler.local.jsonc
  // Errors (console.error) and one-time configuration warnings are always
  // logged regardless of this flag.
  DEBUG_LOGGING?: string;
  // Max photos allowed in a single post. Surfaced to the mobile app via
  // /config so the picker enforces the same cap. Defaults to 5 when unset
  // or invalid; hard-ceilinged at 50.
  MAX_POST_MEDIA?: string | number;
}

export function isDebugEnabled(env: Env): boolean {
  const v = (env.DEBUG_LOGGING ?? '').toLowerCase().trim();
  return v === '1' || v === 'true' || v === 'yes' || v === 'on';
}

export function getMaxPostMedia(env: Env): number {
  const raw = env.MAX_POST_MEDIA;
  if (raw === undefined || raw === null || raw === '') return 5;
  const n = typeof raw === 'number' ? raw : Number(raw);
  if (!Number.isFinite(n) || n < 1) return 5;
  return Math.min(Math.floor(n), 50);
}

export interface AppUser {
  id: string;
  ory_id: string;
  email: string;
  username: string;
  display_name: string;
  avatar_key: string | null;
  is_admin: number;        // 0 or 1
  created_at: number;
}

export function isBootstrapAdmin(env: Env, email: string): boolean {
  const list = (env.ADMIN_EMAILS ?? '')
    .split(',')
    .map((s) => s.trim().toLowerCase())
    .filter(Boolean);
  return list.includes(email.toLowerCase());
}

// Hono context Variables for typed c.get/c.set
export type Variables = {
  oryIdentity: OryIdentity;
  user: AppUser; // populated by requireUser middleware
  // Set to true by oryAuth when the bearer token is a locally-signed demo
  // token (DEMO_USERS path). /me/finalize uses this to skip the allowlist.
  isDemo: boolean;
};

export interface OryIdentity {
  id: string;
  traits: {
    email: string;
    name?: { first?: string; last?: string };
    picture?: string;          // populated by Google OIDC mapper
  };
  verifiable_addresses?: Array<{ verified: boolean; value: string }>;
}
