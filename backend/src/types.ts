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
