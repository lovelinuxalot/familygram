# Architecture

How Familygram is put together, why these pieces were chosen, and how a request flows from a phone tap to a row in D1.

---

## System overview

![Familygram architecture](images/architecture.svg)

> Diagram source: `docs/images/architecture.mmd` (Mermaid `architecture-beta`). Regenerate with `make arch-diagram` — runs the Mermaid CLI with iconify's `logos` + `simple-icons` packs so each vendor logo embeds as inline SVG. We commit the rendered file so it works in every Markdown viewer (GitHub doesn't auto-register Mermaid icon packs).

**What's flowing where**:

- **Sign-in (OIDC)**: the iOS app talks to Ory directly via a native `session_token_exchange_code` flow. Ory hosts the OAuth dance with either Google or Apple (selected by the user on the login screen). The app opens an in-app Safari sheet, the user authenticates with the chosen provider, the provider sends an auth grant to Ory, Ory hands back an opaque `session_token` via the `familygram://callback` URL. One-time per session.
- **API requests**: every authenticated call goes from the app to the Worker as `Authorization: Bearer <session_token>`. The token lives in iOS Keychain (via `flutter_secure_storage`).
- **Token verification**: on each request the Worker calls Ory's `/sessions/whoami` to validate the bearer. Future optimization: switch to a JWT tokenizer template + local JWKS verification to drop the hop — see [ORY_SETUP.md §7](ORY_SETUP.md#7-performance-upgrade-optional-later).
- **Data + media**: the Worker reads/writes D1 (SQLite at the edge) via binding for users/posts/likes/comments, and reads/writes R2 (S3-compatible blob store) for image bytes. No origin server, no managed connection pool — both are accessed as edge-bound services.

Everything inside the Cloudflare box is on the free tier — see the [pricing section in README](../README.md#pricing).

---

## Request lifecycle (an authenticated API call)

What actually happens when the user taps **Like** on a post:

```mermaid
sequenceDiagram
    autonumber
    actor User as 📱 Flutter app
    participant CF as Cloudflare edge
    participant W as Worker (Hono)
    participant Ory as Ory Network
    participant DB as D1

    User->>CF: POST /posts/abc/like<br/>Authorization: Bearer ory_st_...
    CF->>W: routed to nearest PoP
    W->>Ory: GET /sessions/whoami<br/>X-Session-Token: ...
    Ory-->>W: identity { id, traits.email, ... }
    W->>DB: SELECT user WHERE ory_id=...
    DB-->>W: AppUser row
    W->>DB: SELECT tenant memberships
    DB-->>W: [{tenant_id, name, role}]
    W->>DB: INSERT OR IGNORE INTO likes ...
    DB-->>W: ok
    W-->>CF: 200 { ok: true }
    CF-->>User: 200
```

Three things to notice:

1. **TLS termination + DDoS** happens at the edge before the request even reaches our code. Cloudflare's global anycast network routes the user's request to the nearest point of presence, decrypts it, screens it, and forwards to the Worker.
2. **The Worker runs at the edge too** — typically the same region as the user. D1 reads are routed to the database's home region; R2 is globally distributed.
3. **No origin server.** There's no traditional VM, no autoscaling group. The Worker is a function; if no one's using it, it costs nothing and runs nowhere.

---

## Why these tech choices

| Choice | Why                                                                                                                | Alternatives considered                                          |
|--------|--------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------|
| Cloudflare Workers | Edge runtime, single-binding access to D1/R2/Queues, free tier covers thousands of family-day requests.       | AWS Lambda + RDS + S3 (no free tier, more ops); Fly.io (paid).   |
| Hono | Tiny (~12 KB), web-standards routing, type-safe context, very nice middleware story.                                  | Express (heavy, not edge-native); itty-router (smaller but less ergonomic). |
| Cloudflare D1 | SQLite via binding — no connection pool to manage, no server to keep alive, 5 GB free.                          | KV (key-value, not relational); Postgres on Neon (cold-start + connection limits). |
| Cloudflare R2 | S3-compatible, **no egress fees**. Photos served from your own domain.                                            | AWS S3 (egress costs hurt at scale); Cloudinary (paid).         |
| Ory Network | Hosted Kratos. Free for thousands of MAUs. Built-in Google OIDC.                                                   | Auth0 (paid above free tier); rolling your own JWT (don't).      |
| Flutter (iOS-first) | Single codebase reaches Android + web later. Native enough for camera/biometrics.                          | Swift-native (lock-in to Apple); React Native (worse photo libraries). |
| Local Face ID (`local_auth`) | Server-side passkey adds login complexity; local unlock is the right tool for "lock the app, not the auth." | Ory WebAuthn passkeys (deferred — see "Why" doc).            |

---

## Multi-tenancy (families)

One deployment hosts several isolated families ("tenants"). Users can belong to more than one — e.g. a couple that's in both spouses' family feeds.

- **`tenants` + `tenant_members`** is a many-to-many with a per-membership `role` (`admin`/`member` — stored for future per-tenant enforcement; today `users.is_admin` is still the global admin gate). Migration 0007 backfilled the original family as tenant `default` and the App Review sandbox as tenant `demo`, so tenant scoping subsumes the old `users.is_demo` isolation (the column remains for the demo-token auth path).
- **Every post belongs to exactly one tenant** (`posts.tenant_id`). "Post to both families" creates one sibling post row per tenant **sharing the same R2 keys** — media is stored once, but each family gets its own like/comment thread (a comment meant for one family is never shown to the other). `DELETE /posts/:id` only removes R2 objects no surviving `post_media` row still references.
- **Active tenant**: the app sends `X-Tenant-Id` on every request; `requireUser` validates it against the caller's memberships and scopes feed/profile/search queries to it. Post detail (and like/comment on it) accepts *any* of the caller's tenants, so push deep-links from the other family work before the client switches. **No header → first membership**, which keeps pre-tenancy app builds working unchanged.
- **Allowlist is tenant-scoped** (PK `tenant_id, email`): the same email can be invited to several families; first sign-in redeems all pending rows into memberships. Inviting an email that already has an account adds the membership directly (finalize only runs on first sign-in).
- **Push fan-out** targets the union of members across the tenants a post went to; a dual-tenant recipient gets one push, deep-linked to the sibling post in a tenant they belong to. Payloads carry `tenant_id` so the app can switch context on tap.
- Mobile: the active tenant persists in secure storage (`state/tenant.dart`); the feed app bar becomes a family switcher only when the user has 2+ memberships, and the upload composer shows audience chips.

---

## Data model

```mermaid
erDiagram
    TENANTS ||--o{ TENANT_MEMBERS : has
    USERS   ||--o{ TENANT_MEMBERS : "belongs to 1..N"
    TENANTS ||--o{ POSTS          : scopes
    TENANTS ||--o{ ALLOWLIST      : "invites into"
    USERS ||--o{ POSTS      : authors
    USERS ||--o{ COMMENTS   : writes
    USERS ||--o{ LIKES      : gives
    USERS ||--o{ ALLOWLIST  : "added by"
    POSTS ||--|{ POST_MEDIA : "carries 1..N photos"
    POSTS ||--o{ COMMENTS   : has
    POSTS ||--o{ LIKES      : receives

    TENANTS {
        text id PK
        text name
        int created_at
    }
    TENANT_MEMBERS {
        text tenant_id PK
        text user_id PK
        text role
        int created_at
    }
    USERS {
        text id PK
        text ory_id UK
        text email UK
        text username UK
        text display_name
        text avatar_key
        int is_admin
        int is_demo
        int created_at
    }
    ALLOWLIST {
        text tenant_id PK
        text email PK
        text added_by FK
        int added_at
        text used_by FK
        int used_at
    }
    POSTS {
        text id PK
        text user_id FK
        text tenant_id FK
        text caption
        int created_at
    }
    POST_MEDIA {
        text post_id PK
        int idx PK
        text image_key
        text thumb_key
        int width
        int height
    }
    COMMENTS {
        text id PK
        text post_id FK
        text user_id FK
        text body
        int created_at
    }
    LIKES {
        text post_id PK
        text user_id PK
        int created_at
    }
```

A `POSTS` row carries metadata (author, caption, time); the photos themselves live in `POST_MEDIA`, one row per photo, ordered by `idx` from 0. A single-photo post is just one `POST_MEDIA` row; a carousel is multiple. The Worker enforces a hard cap (`MAX_POST_MEDIA`, default 5) on the photo count per post — change the var in `backend/wrangler.jsonc` and redeploy to lift it. The mobile picker reads the same number off `GET /config` so client and server stay aligned.

**Backward-compat shim**: `decoratePost` in `backend/src/index.ts` mirrors `media[0]`'s `image_url` / `thumb_url` / `width` / `height` as top-level fields on the post JSON. Mobile builds shipped before the multi-photo migration read those top-level keys; the shim keeps them working (showing only the first photo) until every install in the wild has updated. Safe to delete the four `first?.*` lines and the comment above them once that's true.

Migrations live in `backend/migrations/`. Run them with `make worker-migrate` (local) or `make worker-migrate-prod` (production).

---

## Storage layout in R2

- `posts/<user_id>/<media_id>.<ext>` / `posts/<user_id>/<media_id>_thumb.<ext>` — staged-upload flow: full image (2000 px max edge, WebP q82) and display tier (1200 px, WebP q80). Keys are minted per *upload*, not per post — a "post to both families" pair of sibling posts points at the same objects. Older posts use the legacy `posts/<user_id>/<post_id>_<idx>.<ext>` or `posts/<user_id>/<post_id>.jpg` shapes; any key is fine, we read whatever `post_media.image_key` says.
- `avatars/<user_id>/<version>.jpg`             — square 256 px avatar; version suffix busts client caches across uploads.

`<idx>` is 0-based and matches the `POST_MEDIA.idx` column, so the carousel order in the UI follows the order on disk.

## Signed media URLs

All R2 reads go through the Worker, gated by an HMAC-SHA256 signature with a 1-hour TTL:

```
GET /media/<scope>/<owner>/<filename>?e=<unix-expiry>&s=<base64url(HMAC)>
```

The Worker signs URLs in the response payloads (feed, post, comments, user) using a `MEDIA_SIGNING_SECRET` Worker secret. The `/media/...` route verifies signature + expiry before fetching from R2. Leaked URLs stop working when they expire.

Signed URLs carry no user or tenant claim — authorization happens where the URL is *minted* (every query that decorates a post is tenant-scoped). Consequence: after removing someone from a family, media URLs they already hold keep working for up to the 1-hour TTL. Accepted trade-off for a family app.

Client side, `cached_network_image` is configured with a stable `cacheKey` (the post id + tier) so URL rotation across hours doesn't trigger re-download — the disk cache hits even with a fresh URL.

---

## Where this could go next

- **JWT tokenizer template** in Ory → drop the per-request whoami hop (saves ~50–100 ms / request).
- **Passkey re-auth** alongside Google sign-in → faster session refresh.
- **Per-tenant roles** — `tenant_members.role` is already stored; enforce it so each family can have its own admin instead of the global `users.is_admin`.
- **Feed dedup for dual-tenant viewers** — a "post to both" pair shows up once per family feed; a member of both sees it twice when switching. Cosmetic only.
- **Retire `users.is_demo`** — the demo world is tenant `demo` now; the flag only survives for the demo-token auth path and the admin users filter.
- **Cloudflare Queues** for fan-out (e.g., notify all family members when a post is created).
- **Cloudflare Stream** when video lands (paid, but native HLS + transcoding worth it).
