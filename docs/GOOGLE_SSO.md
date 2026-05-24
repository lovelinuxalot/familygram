# Google Sign-In setup

Enables "Continue with Google" in Familygram. Four pieces of console clicking, then a test:

1. Customize the Ory identity schema (so `name` + `picture` traits are allowed).
2. Create a Google OAuth client (consent screen + client ID).
3. Add Google as a social provider in Ory (Client ID/Secret, scopes, data mapping).
4. Allowlist `familygram://callback` as a project-level return URL.
5. Test in the app.

Plan for ~25 minutes the first time. Each step ends with a clear "you should see X" so you can sanity-check before moving on.

---

## 1. Customize the Ory identity schema

The default `preset://email` schema only allows `email` as a trait. Sending Google's `name` or `picture` fails with `additionalProperties not allowed`. We replace it with a schema that permits both.

1. Ory Console → **Identity & Account Management → Identity Schema** (or **Customize → Identity Schema**, depending on console version).
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
            "credentials": {
              "password": { "identifier": true }
            },
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

Existing identities (if any) keep working — the new fields are optional.

---

## 2. Create the Google OAuth client

Google Cloud Console splits this into two unrelated screens: the **OAuth consent screen** (app metadata, scopes, test users) and the **OAuth client ID** (redirect URIs). Do them in this order.

### 2a. OAuth consent screen

This is the screen end users see when they grant access. It's configured once per project.

1. Go to https://console.cloud.google.com — create or select a project (e.g. "Familygram").
2. **APIs & Services → OAuth consent screen** (in some console versions: **Branding → OAuth consent screen**).
3. User type: **External**. Create.
4. App name: `Familygram`. User support email: yours. Developer contact: yours.
5. **Authorized domains** → add `oryapis.com`.
6. Save and continue → **Scopes** → "Add or remove scopes":
   - `openid`
   - `.../auth/userinfo.email`
   - `.../auth/userinfo.profile`
7. Save and continue → **Test users** → add your Google account email (and any family members' Google accounts you want to test with) while the app stays in **Testing** mode.
8. Leave it in Testing mode — you don't need to publish. The three scopes above are non-sensitive, so if you ever do want to publish, Google won't require a verification process.

### 2b. OAuth client ID

This is the credential the app uses to talk to Google.

1. **APIs & Services → Credentials → Create credentials → OAuth client ID**.
2. Application type: **Web application**.
3. Name: `Familygram`.
4. **Authorized JavaScript origins**: leave blank — the OAuth flow is server-to-server between Google and Ory, not browser-to-Google.
5. **Authorized redirect URIs**: leave blank for now. You'll paste Ory's callback URL here after step 3 (Ory prints it once you create the provider).
6. Click **Create**. Save the **Client ID** and **Client Secret** it shows you — you'll paste them into Ory in step 3.

---

## 3. Add Google as social provider in Ory

Open **Authentication → Social Sign-In (OIDC)** → **Add social sign-in provider** → **Google**.

1. **Provider ID**: leave the default (`google`) — the Flutter app references this name.
2. **Client ID** / **Client Secret**: paste the values from Google Cloud step 2b.
3. **Base Redirect URI**: **leave this empty** (or, if the field is required, paste your Ory project URL like `https://<your-slug>.projects.oryapis.com`). Despite its name, this field is the base URL Ory uses to build its *own server-side* OAuth callback URL — it must be Ory's domain, **not** the mobile URI scheme. Putting `familygram://callback` here makes Google reject the OAuth request because the resulting `redirect_uri` becomes nonsensical.
4. Expand **Advanced settings**:
   - **Scope**: `openid`, `email`, `profile` (three separate chips/entries).
   - **Data mapping (Jsonnet)**: paste the snippet below.

   ```jsonnet
   local claims = std.extVar('claims');
   {
     identity: {
       traits: {
         email: claims.email,
         name: {
           first: if 'given_name' in claims then claims.given_name else '',
           last:  if 'family_name' in claims then claims.family_name else '',
         },
         picture: if 'picture' in claims then claims.picture else '',
       },
     },
   }
   ```
5. **Save**. Ory now displays the Google **Authorized Redirect URI** on the provider page. It includes a per-provider suffix — for example:
   ```
   https://<your-slug>.projects.oryapis.com/self-service/methods/oidc/callback/google--I75TIYk
   ```
   The `--<code>` part is Ory's unique identifier for this provider config (a different code per provider you add). **Copy the whole URL exactly as Ory shows it** — including the suffix. The plain `/google` form without the suffix won't match what Ory sends to Google at runtime.
6. Back in **Google Cloud → APIs & Services → Credentials → your OAuth client → Authorized redirect URIs** → click **Add URI** → paste the full URL from step 5 → **Save**.

## 4. Allowlist the mobile callback (`familygram://callback`)

The Flutter app receives the OAuth result at `familygram://callback`. Ory must explicitly allow this as a `return_to` target, or it silently redirects to its default UI fallback (`/ui/welcome`) instead.

In the Ory Console:

1. Top nav → **Branding**.
2. Left sidebar → **Browser redirects**.
3. Top tab → **Global redirects**.
4. Scroll to **Allowed URLs (optional)**.
5. Paste `familygram://callback` → click the **+** button to add it → **Save**.

You can leave **Global redirect URL** at its default `/ui/welcome` — that's only used when no `return_to` is sent, which isn't our case.

Equivalent via Ory CLI:

```bash
ory list projects                          # find your project id
ory patch project --project <project-id> \
  --add '/services/identity/config/selfservice/allowed_return_urls=["familygram://callback"]'
```

**Sanity check**: in Ory's "Test connection" flow from the Google provider page, Google should show its usual consent screen (with your app name "Familygram" and your test user email). If you instead see *Error 400: invalid_request* with `redirect_uri=familygram://callback/...`, the **Base Redirect URI** in step 3.3 is still set to `familygram://callback` — clear it.

---

## 5. Test in the app

1. Add your Google account's email to the Familygram **allowlist** (Admin → Allowlist → Add).
2. In the app, tap **"Continue with Google"**.
3. iOS opens an in-app Safari sheet → Google OAuth → you grant Familygram.
4. The sheet closes; the app shows the feed with your Google name and avatar.

**If you see "needs an invite" or "your email isn't on the family list"** — the OAuth completed but the email isn't allowlisted. Add it as admin and try again.

**If you see "Ory did not return a Google redirect URL"** — the Google provider isn't wired up in Ory yet, or scopes are missing.

**If the OAuth sheet hangs** — likely the `familygram://callback` redirect isn't allowlisted in Ory. See step 4.

---

## What runs server-side after a successful Google sign-in

The Worker's `/me/finalize` endpoint does, in order:

1. Check the email against the allowlist (or `ADMIN_EMAILS`).
2. Create the `users` row using:
   - `email` from Google (lowercased)
   - `display_name` from `given_name + family_name`
   - `username` auto-derived from the email local-part (with a numeric suffix if taken)
3. Best-effort fetch the Google profile picture URL and store the JPEG bytes in R2 at `avatars/<user_id>/<version>.jpg`. The avatar is then served from your own R2 bucket — no runtime dependency on Google's CDN.

If anything in step 3 fails (Google CDN hiccup, image unreachable), the user is created with `avatar_key = null` — they get a placeholder avatar and can upload one from the profile screen.
