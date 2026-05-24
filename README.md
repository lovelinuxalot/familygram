# Familygram

A private, invite-only photo feed for families. Google sign-in, allowlist access, Face ID unlock, comments with @mentions. Runs on Cloudflare's free tier; the only paid component is the Apple Developer Program ($99/yr) when you're ready to ship to family via TestFlight.

- **What's in it** → [docs/RELEASE_NOTES.md](docs/RELEASE_NOTES.md)
- **How it's built** → [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- **How to deploy it** → [docs/DEPLOY.md](docs/DEPLOY.md)

---

## At a glance

| Layer        | Tech                                             |
|--------------|--------------------------------------------------|
| Mobile       | Flutter (iOS-first)                              |
| API          | Cloudflare Workers (Hono + TypeScript)           |
| Database     | Cloudflare D1 (SQLite at the edge)               |
| Object store | Cloudflare R2 (no egress fees)                   |
| Auth         | Ory Network (Kratos identities, Google OIDC)     |
| Bio unlock   | Apple Face ID / Touch ID via `local_auth`        |

For the wiring (and *why* each of these was chosen), see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

---

## Pricing

| Service              | Free tier                                            | Family-of-20 usage     |
|----------------------|------------------------------------------------------|------------------------|
| Cloudflare Workers   | 100k requests/day                                    | ~5k/day max            |
| Cloudflare D1        | 5 GB storage, 5M reads/day, 100k writes/day          | sub-1%                 |
| Cloudflare R2        | 10 GB storage, **no egress fees**                    | ~25k+ photos           |
| Ory Network          | thousands of MAUs                                    | 20 users               |
| Apple Developer      | $99/year (only for TestFlight / App Store)           | required for iPhones   |

**Cost for a family of 20: $0/month + the $99/yr Apple Dev once you ship to TestFlight.**

---

## Repo layout

```
familygram/
├── backend/           # Cloudflare Worker (Hono + TS)
├── mobile/            # Flutter app (iOS-first)
├── docs/
│   ├── ARCHITECTURE.md      # diagrams, request flow, tech choices
│   ├── DEPLOY.md            # first-time deploy walkthrough
│   ├── ORY_SETUP.md         # Ory Network configuration
│   ├── GOOGLE_SSO.md        # Google Cloud + Ory social provider
│   ├── APPLE_SSO.md         # Apple Sign-in setup (required for App Store)
│   ├── ANDROID_RELEASE.md   # Keystore + Play Console internal testing
│   └── RELEASE_NOTES.md     # what shipped, when
├── scripts/
│   ├── ship-testflight.sh   # build + upload TestFlight build
│   ├── ship.env.example     # config template for the above
│   └── RELEASE.md           # one-time TestFlight setup
├── Makefile           # daily commands
└── README.md          # you are here
```

---

## Daily commands

`make help` lists everything. The ones you'll touch most:

| Command             | What it does                                              |
|---------------------|-----------------------------------------------------------|
| `make worker`       | Start the Worker locally on `:8787` (with local D1 + R2). |
| `make sim`          | Boot an iOS simulator.                                    |
| `make dev`          | Run the Flutter app on the booted simulator.              |
| `make clean`        | Wipe build artifacts (do before a fresh native rebuild).  |
| `make setup`        | Install Flutter deps + Worker deps + iOS pods.            |
| `make analyze`      | Flutter lint pass.                                        |
| `make tc`           | Typecheck both Worker (`tsc`) and Flutter (`analyze`).    |
| `make icon`         | Regenerate the app icon set.                              |
| `make splash`       | Regenerate the iOS launch screen.                         |
| `make release-note` | Open `docs/RELEASE_NOTES.md` for editing.                 |
| `make release-note-add` | Auto-generate a new entry from commits since the last release. Version is computed from conventional-commit prefixes (`feat:`→minor, `fix:`→patch, `feat!:`/`BREAKING CHANGE`→major). Pass `VERSION=x.y.z` to override. |
| `make build` | Release-build both IPA and AAB (no version bump, no upload). |
| `make build-ios` / `make build-android` | Build just one of the two. |
| `make ship` | Build + upload both: TestFlight (auto) + Play Console (prints next step). Optional `VERSION=x.y.z`. |
| `make ship-ios` / `make ship-android` | Ship just one platform. |

A typical dev session:

```bash
make worker   # terminal 1 — Worker on :8787
make sim      # boot the simulator
make dev      # terminal 2 — Flutter on the simulator
```

After native iOS changes (Info.plist, plugin add, icon, splash): `make clean && make setup && make dev`.

---

## Initial setup (one-time, fresh clone)

These steps establish the auth providers and the Cloudflare resources Familygram needs. They're done **once** — they're not specific to dev or prod; the same Ory project and the same Google OAuth client back both environments.

1. **Install deps**: `make setup`.
2. **Configure Ory Network**: walk through [docs/ORY_SETUP.md](docs/ORY_SETUP.md).
3. **Configure Google SSO** and **Sign in with Apple**: walk through [docs/GOOGLE_SSO.md](docs/GOOGLE_SSO.md) and [docs/APPLE_SSO.md](docs/APPLE_SSO.md). Apple is required for App Store approval if you offer Google sign-in.
4. **Create Cloudflare resources** (D1 database + R2 bucket); paste IDs into `backend/wrangler.jsonc`. Details in [docs/DEPLOY.md](docs/DEPLOY.md).

Steps 2 and 3 are the longest (~30 min); steps 1 and 4 are a couple of commands.

---

## Going to production

Once [Initial setup](#initial-setup-one-time-fresh-clone) is done and the app works against `make worker` on the simulator, going to production is just three things:

1. **Apply schema to remote D1**:

   ```bash
   make worker-migrate-prod
   ```

2. **Set the Worker secrets**:

   ```bash
   cd backend

   # Comma-separated emails that auto-become admins on first sign-in
   npx wrangler secret put ADMIN_EMAILS

   # 32-byte random HMAC key for signing media URLs (required)
   openssl rand -hex 32 | npx wrangler secret put MEDIA_SIGNING_SECRET
   ```

3. **Deploy the Worker**:

   ```bash
   make worker-deploy
   # → prints https://<your-worker>.<your-handle>.workers.dev
   ```

Smoke-test by pointing the simulator at production:

```bash
make dev DEV_API_BASE=https://<your-worker>.<your-handle>.workers.dev
```

---

## Releasing builds

For families that span platforms — both iOS via TestFlight and Android via Play Console internal testing.

### One-time setup

- **iOS / TestFlight**: enroll in the [Apple Developer Program](https://developer.apple.com/programs/) ($99/yr) and follow [scripts/RELEASE.md](scripts/RELEASE.md).
- **Android / Play Console**: sign up for the [Play Console](https://play.google.com/console/signup) ($25 one-time) and follow [docs/ANDROID_RELEASE.md](docs/ANDROID_RELEASE.md).

### Every release after that

```bash
# Ship both platforms at once. Bumps build number, builds, uploads to TestFlight,
# builds the Android AAB and prints the path to drag into Play Console.
make ship VERSION=1.2.0

# Or one platform at a time:
make ship-ios VERSION=1.2.0    # iOS only (uploads automatically)
make ship-android              # Android only (build + manual Play Console upload)

# Or just produce both artifacts without bumping/uploading:
make build
```

TestFlight builds expire 90 days after upload; Play Console internal testing builds don't expire. Either run `make ship` periodically, or submit to App Store / Play Production for indefinite lifetime — both paths are in the respective release docs.

---

## License

[MIT](LICENSE) — fork it, run it for your family, modify as you like. No warranty.
