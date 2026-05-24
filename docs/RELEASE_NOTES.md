# Familygram release notes

Newest at the top.

Update with `make release-note` (opens this file in `$EDITOR`) or `make release-note-add VERSION=1.1.0` to prepend a fresh entry template.

---

## v1.1.0 — pre-launch hardening

Everything we wanted in place before pushing to TestFlight / App Store.

### Added
- **Sign in with Apple** alongside Google. Required by Apple Guideline 4.8 for App Store approval when offering Google sign-in. Setup: [docs/APPLE_SSO.md](APPLE_SSO.md).
- **Share button** on every feed tile and on the post detail screen. Downloads the full-resolution image and opens the native iOS share sheet (Save to Photos, Messages, AirDrop, etc.).
- **Comments bottom sheet** — tap the comment icon on a feed tile to open a draggable modal with the comment list + composer (with mention autocomplete). No more navigating to `/post/:id` just to see comments; Instagram-style.
- **Delete-own-post menu** in the feed — three-dot icon on the tile header for your own posts.
- **"View N comments" link** at the bottom of each tile when comments exist.
- **Privacy policy** served from the Worker at `/privacy` (single HTML page), linked from the Profile screen.
- **Delete my account** action on the Profile screen — wipes posts, comments, likes, allowlist entry, R2 media in one go via `DELETE /me`.

### Security
- **Signed media URLs** replace public R2 URLs. The Worker mints short-lived (1 h) HMAC-SHA256–signed URLs in feed/post/comment payloads; the `/media/...` route rejects invalid or expired signatures. Required new Worker secret: `MEDIA_SIGNING_SECRET` (`openssl rand -hex 32 | npx wrangler secret put MEDIA_SIGNING_SECRET`).

### Changed
- **Image quality bumped**. Display tier (thumb) is now 1200 px / q88 (was 400 px / q75). Full tier (used for share/download) is 2000 px / q88. The feed looks crisp at @3x retina widths.
- **`ITSAppUsesNonExemptEncryption = false`** in `Info.plist` so App Store Connect stops asking about export compliance per build.
- Tapping a photo on the feed now opens the full-screen image viewer (was: navigate to post detail). Photo viewer reuses the same signed URL with a stable cache key, so no re-download.
- The `/post/:id` route still exists for deep links but is no longer the entry point for comments.

### Fixed
- iPad share-sheet "sharePositionOrigin" error — share button now captures its own `RenderBox` via a `Builder` so the popover anchors correctly.

---

## v1.0.0 — initial release

The first cut. Photo-feed parity with Instagram for the bits that matter to a family.

### Auth & access
- Google sign-in via Ory Network OIDC (`session_token_exchange_code` native flow).
- Admin-curated **email allowlist** instead of invite codes; admins added via `ADMIN_EMAILS` env.
- In-app admin panel: add / remove emails, list members, promote-to-admin toggle.
- Auto-imports the user's Google display name + avatar on first sign-in.
- Local **Face ID / Touch ID / passcode** lock on cold start and on resume after 60 s in background.

### Posting & viewing
- Photo upload from camera or library, client-side resize to 1600 px + 400 px thumbnail.
- Feed shows the 400 px thumbnail (~30 KB) to save data; full image loads only on tap.
- 3-column photo grid on each user's profile.
- Pinch-to-zoom image viewer.
- Caption with `username` + tappable @mentions; truncated past 140 chars with more/less toggle.

### Comments & social
- Comments with @mentions and live autocomplete dropdown (`@<chars>` → suggestion list from `/users/search`).
- Tappable mentions resolve to the user's profile.
- Likes with optimistic UI + revert on failure.
- Tapping any name or avatar opens that user's profile.

### Surface & UX
- Custom "stacked polaroids" app icon, generated programmatically (`mobile/tool/generate_icon.dart`).
- Navy splash screen via `flutter_native_splash`.
- Light + dark theme following system; "deep ocean" navy palette.
- Bottom nav with Home + Profile + centered camera FAB.
- Toast feedback for upload / delete / like / comment errors.
- Skeleton tiles during initial feed load.
- Friendly relative time formatting ("Yesterday at 3:42 PM", "Mon at 2:01 PM").

### Infrastructure
- Cloudflare Workers (Hono + TS) + D1 + R2.
- iOS bundle id `cc.lovelinuxalot.familygram` (changeable in Xcode + `project.pbxproj`).
- `Makefile` with daily commands (dev / setup / clean / ship).
- `scripts/ship-testflight.sh` for one-command TestFlight releases.

### Deferred for later
- Push notifications (FCM via APNs — needs paid Apple Dev account).
- Video (Cloudflare R2 + range requests; encoding TBD).
- Photo tagging (positional pins inside the image).
- Ory passkey re-auth (Face ID-based session refresh, alongside Google).
- Android + web builds (codebase supports both; only iOS is wired up).
- Email invitations (Resend or similar) so allowlisted relatives get a notification.
