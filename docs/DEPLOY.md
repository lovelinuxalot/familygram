# Deploy Familygram

End-to-end first-time setup, from fresh clone to "family installs from TestFlight."

Time budget: ~90 minutes total, mostly waiting on Apple to verify your developer account.

If you just want the daily commands, see the [README](../README.md#daily-commands).

---

## Prerequisites

| Need                                           | Why                                                              |
|------------------------------------------------|------------------------------------------------------------------|
| macOS with Xcode (full, not just CLI tools)    | Required to build iOS apps and use the simulator.                |
| [Flutter SDK](https://docs.flutter.dev/get-started/install/macos) | Mobile app build.                              |
| Node 20+ (npm)                                  | Worker dev + deploy.                                             |
| [Cloudflare account](https://dash.cloudflare.com) (free) | Hosts the Worker + D1 + R2.                            |
| [Ory Network account](https://console.ory.sh) (free) | Auth (Google SSO).                                          |
| [Google Cloud account](https://console.cloud.google.com) (free) | OAuth client for Google sign-in.                    |
| iPhone with iOS 13+                            | Test device. Simulator works fine for everything except the camera. |
| Apple Developer Program ($99/yr)               | Required for TestFlight / App Store. Skip if just testing on simulator. |

---

## 1. Clone + install dependencies

```bash
git clone <your-fork-url> familygram
cd familygram
make setup
```

`make setup` runs `flutter pub get`, `npm install`, and `pod install`. The first run takes a couple of minutes.

---

## 2. Configure Ory Network

Walk through [ORY_SETUP.md](ORY_SETUP.md):

- Create a project.
- Customize the identity schema (allows `name` + `picture` traits).
- Confirm self-service login + registration flows are enabled.

Note your project URL: `https://<slug>.projects.oryapis.com`. You'll use it everywhere as `ORY_BASE`.

---

## 3. Configure social sign-in

Walk through both, in order:

1. [GOOGLE_SSO.md](GOOGLE_SSO.md): Google Cloud OAuth client, Ory social provider, `familygram://callback` allowed return URL.
2. [APPLE_SSO.md](APPLE_SSO.md): Apple Developer Services ID, Sign-In with Apple key, Ory social provider. **Required for App Store approval** when offering Google sign-in.

---

## 4. Create Cloudflare resources

```bash
cd backend
npx wrangler login                              # one-time browser auth
npx wrangler d1 create familygram               # prints a database_id
npx wrangler r2 bucket create familygram-media  # creates the media bucket
```

Now copy the committed template to a gitignored local config and edit it:

```bash
cp backend/wrangler.jsonc backend/wrangler.local.jsonc
```

Open `backend/wrangler.local.jsonc` and fill in:

- `vars.ORY_SDK_URL` — your Ory project URL (`https://<slug>.projects.oryapis.com`).
- `vars.MEDIA_PUBLIC_BASE` — `https://<your-worker>.<your-cf-handle>.workers.dev/media` (you'll know the exact URL after the first deploy; for now, guess based on your Workers handle and the `name` you set in this file, and adjust later).
- `vars.CORS_ORIGINS` — leave `""` unless you also serve a browser client. Mobile clients don't need CORS.
- `d1_databases[0].database_id` — the UUID printed by `wrangler d1 create familygram`.

The committed `backend/wrangler.jsonc` stays as a template with placeholders so the repo carries no deployment-specific URLs / IDs. `wrangler.local.jsonc` is gitignored; the Makefile prefers it when present.

> **Optional: dev URL overrides.** If you want `make dev` to pre-fill your Ory URL without typing it every time, `cp scripts/dev.env.mk.example scripts/dev.env.mk` and set `DEV_ORY_BASE` there. Also gitignored.

---

## 5. Apply D1 migrations

```bash
make worker-migrate-prod
```

Schema is created in your production D1.

---

## 6. Configure Worker secrets

```bash
cd backend

# Comma-separated emails granted admin status on first sign-in.
npx wrangler secret put ADMIN_EMAILS
#   you@example.com,partner@example.com

# 32-byte random HMAC key used to sign media URLs. Required — the Worker
# will throw at /media requests if this isn't set. Also used to sign demo
# tokens, so rotating it invalidates any outstanding App-Review demo sessions.
openssl rand -hex 32 | npx wrangler secret put MEDIA_SIGNING_SECRET
```

You can change `ADMIN_EMAILS` later — admins can also promote other users via the in-app admin panel. `MEDIA_SIGNING_SECRET` can be rotated; rotating invalidates outstanding signed URLs (clients re-fetch the feed and get fresh ones).

There's also an **optional** `DEMO_USERS` secret used only for App Store / Play Store review — see [Demo mode for App Store review](#demo-mode-for-app-store-review) below. Leave it unset for normal operation.

---

## 7. Deploy the Worker

```bash
make worker-deploy
# → prints https://<your-worker>.<your-handle>.workers.dev
```

Health check:

```bash
curl https://<your-worker>.<your-handle>.workers.dev/health
# → {"ok":true}
```

Save the URL — you'll use it as `API_BASE`.

---

## 8. Smoke-test on the iOS simulator

```bash
cd ..    # back to repo root
make sim                                              # boots an iPhone simulator
make dev DEV_API_BASE=https://<your-worker>.<your-handle>.workers.dev
```

In the app: **Continue with Google** → pick the account whose email is in `ADMIN_EMAILS` → Familygram opens to an empty feed.

Tap the **You** tab → tap **Family admin** → add another email to the allowlist for a family member.

That's your production backend confirmed working. Now you need a real iOS build.

---

## 9. Install on a real iPhone (free, 7-day cert)

Cheapest test option. The build expires after 7 days; reinstall via cable.

1. Plug iPhone into Mac. Tap **Trust** on the phone.
2. Open `mobile/ios/Runner.xcworkspace` in Xcode.
3. **Runner** target → **Signing & Capabilities**:
   - Team: your personal Apple ID (add via Xcode → Settings → Accounts if missing).
   - Bundle Identifier: starts as `cc.lovelinuxalot.familygram`. If Apple rejects (already-taken globally), append your name: `cc.lovelinuxalot.familygram.<yourname>`.
4. From the repo root:

   ```bash
   make dev DEV_API_BASE=https://<your-worker>.<your-handle>.workers.dev
   ```

5. On the iPhone: **Settings → General → VPN & Device Management → your Apple ID → Trust**. Then re-launch the app.

The cable-and-Mac dance only matters for free signing. **TestFlight skips all of this** — see next section.

---

## 10. Going to TestFlight

This is the proper distribution path for family use. Requires the $99/yr Apple Developer Program.

The full one-time setup is in [scripts/RELEASE.md](../scripts/RELEASE.md). Summary:

1. Enroll at https://developer.apple.com/programs/ (~24-48 h verification).
2. Create the app record in App Store Connect.
3. Create an App Store Connect API key, save the `.p8` and IDs.
4. `cp scripts/ship.env.example scripts/ship.env` and fill it in.
5. Configure paid-team signing in Xcode.
6. First `Product → Archive` in Xcode to confirm signing works.

From then on, every release is:

```bash
make ship
```

Family members install via the TestFlight app on iOS. Builds expire after 90 days — calendar yourself a reminder, or `make ship` whenever you ship a feature.

---

## Adding a family member

Once you (the admin) are signed in:

1. Tap **You** tab → **Family admin**.
2. **Allowlist** tab → enter their Google email → **Add**.
3. Text them: "Install Familygram from TestFlight (link), tap Continue with Google, sign in with `<their-email>`."

Their first sign-in auto-creates their app account using the name and avatar Google supplies. They land directly on the feed.

To revoke access: same page, delete the email from the allowlist. Their existing posts stay; they just can't log back in.

---

## Demo mode for App Store review

Apple's App Review team can't complete Google / Apple sign-in (they don't have your family's Google accounts on the allowlist), and they explicitly refuse to receive one-time codes by SMS. **Guideline 2.1(a)** lists three acceptable workarounds; we ship the third one: a **demonstration mode** that lets the reviewer sign in with a fixed email + password.

Demo mode is **off by default** — the form doesn't render and the endpoint 404s — and is toggled on for the duration of an App Review submission by setting a single Worker secret.

### How it works

- **Backend gate**: `DEMO_USERS` is a comma-separated list of `email:password` pairs (e.g. `review@apple.com:Apple-Review-2026!`). When non-empty:
  - `GET /config` returns `{"demo_mode": true}`.
  - `POST /auth/demo` accepts credentials from that list and returns a locally-signed bearer token (HMAC-SHA256 over a 24 h–TTL payload, signed with `MEDIA_SIGNING_SECRET`).
  - `oryAuth` recognizes the `demo.` prefix and verifies tokens locally — no Ory call.
  - `/me/finalize` bypasses the allowlist for demo identities so the reviewer is auto-onboarded.
- **Mobile gate**: the login screen fetches `/config` on mount and only renders the email/password form when `demo_mode == true`.

The mobile UI flag is purely cosmetic — even a tampered client showing the form gets a 404 from `/auth/demo` when `DEMO_USERS` is empty. The single source of truth is the backend env var.

### Enabling for a submission

```bash
cd backend

# One credential pair:
echo 'review@apple.com:Apple-Review-2026!' | npx wrangler secret put DEMO_USERS

# Or several, comma-separated:
echo 'a@x.com:pw1,b@y.com:pw2' | npx wrangler secret put DEMO_USERS

npx wrangler deploy
```

In **App Store Connect → App Review Information**, paste the demo credentials and add a note:

> Demo mode: open the app, scroll past "Sign in with Apple" / "Continue with Google" to the "or sign in with demo account" card, enter the email and password above. No SMS code required.

The mobile app must be on a build that includes the demo login screen (shipped in the same release where `DEMO_USERS` was added) — older builds won't render the form even if the backend reports `demo_mode: true`.

### Disabling after approval

```bash
cd backend
npx wrangler secret delete DEMO_USERS
npx wrangler deploy
```

Effect, immediately on the next request:

- `/config` returns `{"demo_mode": false}` → mobile UI stops rendering the form on next launch.
- `/auth/demo` returns 404.
- Outstanding demo tokens stop validating — verification re-checks `DEMO_USERS` on every request, so removing the email from the list invalidates the token even before its 24 h TTL expires.

No mobile rebuild is required to disable demo mode.

### Security notes

- `DEMO_USERS` is a **secret**, not a `vars` entry — never commit it to `wrangler.jsonc`. Use `wrangler secret put` (which encrypts it at rest in Cloudflare).
- Demo users bypass the family allowlist by design; do not add a real family-member email to `DEMO_USERS`.
- Demo users are never granted admin (no matter what `ADMIN_EMAILS` says).
- Rotating `MEDIA_SIGNING_SECRET` invalidates all outstanding demo tokens, since they share the same signing key.

---

## Anti-abuse hardening

If you publish the repo (so other families can fork it), the URLs that identify *your* deployment are already gone — `wrangler.local.jsonc` and `scripts/dev.env.mk` are gitignored. But a determined attacker who learns your Worker URL (e.g. someone in your family forwards it, or it shows up in a network capture) could still hammer it to chew through your free-tier quotas. Four layers of defense are wired in:

1. **Per-IP rate limit (in-Worker, free).** `backend/src/index.ts` calls `env.RATE_LIMITER.limit({ key: <CF-Connecting-IP> })` on every request except `/health`. The binding is declared in `wrangler.jsonc` as 120 req/minute per IP — enough headroom for feed scrolling, tight enough to kill obvious bots. Tune `simple.limit` / `simple.period` to taste. Excess requests get HTTP 429 — they don't burn your D1 / Ory budget.

2. **CORS gate.** `vars.CORS_ORIGINS` is empty by default. Cross-origin browser XHR is blocked; native mobile (no `Origin` header) is unaffected. If you ever add a web client, add its origin (e.g. `https://app.example.com`) — comma-separate for multiples.

3. **Cloudflare WAF rate-limit rule (dashboard, free).** Belt-and-suspenders on top of the in-Worker limit, applied *before* the request reaches your Worker:

   - **Workers & Pages → \<your Worker\> → Security → WAF → Rate limiting rules → Create rule.**
   - Field: `URI Path`, Operator: `equals`, Value: `/auth/demo`. Rate: 5 / 1 minute. Action: Block.
   - Repeat for `/me/finalize` (10 / 1 minute) and a catch-all `(starts_with "/")` at 200 / 1 minute as a global cap.

   The free plan allows 5 rate-limit rules, which is plenty for this app.

4. **Ory anti-abuse.** Familygram relies on Ory's "register on first sign-in via Google OIDC" flow, so you can't simply disable self-service registration — new family members would never get an identity. Instead:

   - In the Ory dashboard, confirm the **OAuth2 / OIDC providers** allowlist only the redirect URLs you actually use (`familygram://callback`). Anything else won't complete the flow.
   - Ory Network has rate-limits per project enabled by default; nothing to configure, but be aware that abusive sign-up attempts count against your monthly active user quota until they're cleaned up. If you see a spike, **Identities → bulk delete** unallowlisted identities, and consider adding a **Webhook / Action** on the registration flow that pre-checks the email against your D1 allowlist before completing — this needs a public endpoint on the Worker that Ory can call.

The first two are committed to this repo and active on every deploy. The third and fourth are dashboard settings — open them when you bring up a new deployment and tick them off.

---

## Troubleshooting

**`curl /health` works but `/me` returns 401** — bearer token isn't being accepted. Most often: `ORY_SDK_URL` in `wrangler.local.jsonc` doesn't exactly match your Ory project URL (trailing slash, wrong slug). Fix and redeploy.

**Google sign-in opens then bounces back without a code** — the `familygram://callback` URL isn't in Ory's allowed return URLs. See [GOOGLE_SSO.md](GOOGLE_SSO.md#4-allowlist-the-mobile-callback-familygramcallback).

**"Your email isn't on the family list"** after a successful Google sign-in — that email isn't in the allowlist or `ADMIN_EMAILS`. Admin (or first-bootstrap email) must add it.

**`flutter run` doesn't show your iPhone in `flutter devices`** — phone is locked, or "Trust this computer" wasn't accepted, or developer mode isn't enabled (iOS 16+: Settings → Privacy & Security → Developer Mode).

**Image upload returns 413** — image exceeds 12 MB after client-side resize. Increase the cap in `backend/src/index.ts` if needed, but normal phone photos should land under 1 MB after resizing.

**`pod install` fails with version mismatch** — `cd mobile/ios && pod repo update && pod install`. If still failing, `make clean && make setup`.

**TestFlight build sticks at "Processing"** — Apple's backend is sometimes slow. Wait an hour. If still stuck after 24 hours, check your email for an Apple-side rejection.

**Demo login form doesn't appear on the login screen** — confirm `curl https://<your-worker>/config` returns `{"demo_mode": true}`. If it returns `false`, `DEMO_USERS` isn't set (or is empty); `wrangler secret put DEMO_USERS` and redeploy. If it returns `true` but the form still doesn't show, the installed mobile build predates the demo-mode feature — ship a new build.

**Demo login returns 401 "invalid demo credentials"** — the email/password pair isn't in `DEMO_USERS`. Re-set the secret with the exact `email:password` format (no quotes, no spaces around the colon) and redeploy.
