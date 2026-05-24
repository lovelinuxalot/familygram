# Ory Network setup for Familygram

Familygram uses [Ory Network](https://www.ory.sh) (Kratos identities) for authentication. The flow:

1. The Flutter app starts an OIDC flow against Ory directly using the native `session_token_exchange_code` pattern.
2. Ory redirects the user to Google for sign-in.
3. After Google OAuth completes, Ory issues a session token.
4. The app sends that token to our Worker as `Authorization: Bearer <token>`.
5. The Worker verifies it by calling Ory's `/sessions/whoami`.

The Google sign-in side is documented in [GOOGLE_SSO.md](GOOGLE_SSO.md). This doc covers the Ory-only pieces.

---

## 1. Create the project

1. Sign in at https://console.ory.sh and create a new project.
2. Pick a region close to you (US/EU).
3. Note the project URL — `https://<slug>.projects.oryapis.com`. You'll plug it into `backend/wrangler.jsonc` as `ORY_SDK_URL` and into Flutter as `ORY_BASE`.

---

## 2. Custom identity schema (mandatory)

The default schema (`preset://email`) only permits an `email` trait. We need `name` and `picture` too so Google's profile data can populate the Ory identity. Without this, Google sign-in fails with `additionalProperties "name" not allowed`.

1. **Identity & Account Management → Identity Schema → Edit** (or **Customize → Identity Schema**, depending on console version).
2. Choose **"Custom schema (advanced)"** → paste the JSON below.
3. Save.

```json
{
  "$id": "https://schemas.familygram.app/v1/identity.schema.json",
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "Familygram user",
  "type": "object",
  "properties": {
    "traits": {
      "type": "object",
      "properties": {
        "email": {
          "type": "string",
          "format": "email",
          "title": "Email",
          "minLength": 3,
          "maxLength": 320,
          "ory.sh/kratos": {
            "credentials": { "password": { "identifier": true } },
            "verification": { "via": "email" },
            "recovery":     { "via": "email" }
          }
        },
        "name": {
          "type": "object",
          "properties": {
            "first": { "type": "string", "title": "First name", "maxLength": 100 },
            "last":  { "type": "string", "title": "Last name",  "maxLength": 100 }
          }
        },
        "picture": {
          "type": "string",
          "format": "uri",
          "title": "Profile picture URL"
        }
      },
      "required": ["email"],
      "additionalProperties": false
    }
  }
}
```

---

## 3. Self-service flows

Under **Authentication → Self-service**:

- **Login**: enabled (default).
- **Registration**: enabled. The Worker's `/me/finalize` endpoint then checks the email against your allowlist (set via `ADMIN_EMAILS` env var + admin panel) before creating an app user row — Ory is identity, not authorization.
- **Verification**: optional. The app never gates on verification; safe to leave at the default.
- **Recovery**: not used by Familygram (we don't have a password reset flow because we only use Google sign-in), but leaving it on doesn't hurt.

---

## 4. Browser redirects (allowed return URLs)

For Google sign-in to complete on a native iOS app, Ory needs to know `familygram://callback` is a safe redirect target.

1. **Branding → Browser redirects → Global redirects**.
2. **Allowed URLs (optional)**: add `familygram://callback`. Click `+`. Save.

Equivalent Ory CLI command:

```bash
ory list projects
ory patch project --project <project-id> \
  --add '/services/identity/config/selfservice/allowed_return_urls=["familygram://callback"]'
```

---

## 5. SMTP

Familygram doesn't send any emails through Ory in the current design (Google handles user identity end-to-end; we don't trigger email verification or password resets). You can leave the default Ory mail server settings alone.

If later you want password recovery email or email verification, configure SMTP under **Project settings → Mail server** (Resend, Postmark, SES, etc.).

---

## 6. CORS

You don't need to configure anything here. The iOS app calls Ory directly (native flows skip browser CORS entirely). Flutter Web is not currently a target; if added later, it'd need the Worker to proxy Ory calls or Ory Tunnel for local dev — see comments in `mobile/lib/api/ory_client.dart`.

---

## 7. Performance upgrade (optional, later)

The Worker calls `Ory /sessions/whoami` on every authenticated request. That's ~50–100 ms of latency added to each API call. Fine for v1; if you want to remove it:

1. Ory Console → **Authentication → Session tokenizer templates** → add a template that emits a JWT (RS256, claims include `sub` and the relevant traits).
2. Flutter exchanges its session token for a JWT after sign-in: `GET /sessions/token/exchange?template=<id>` (or whatever the current Ory CLI exposes).
3. The Worker switches `auth.ts` to verify the JWT locally against Ory's JWKS at `/.well-known/jwks.json` (using the [`jose`](https://www.npmjs.com/package/jose) npm package, which works in Workers).

This isn't done in v1 because the simple whoami flow has zero setup overhead.
