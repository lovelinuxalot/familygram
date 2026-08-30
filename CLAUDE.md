# Familygram

Private, invite-only family photo feed. Flutter (iOS-first, Android shipping) + Cloudflare Worker (Hono/TS) + D1 + R2 + Ory auth.

Full context lives in the `familygram` skill at `.claude/skills/familygram/SKILL.md` — auto-loads when you work on features here. Authoritative reference docs:

- `README.md` — stack, daily commands, deploy
- `docs/ARCHITECTURE.md` — request flow, data model, R2 layout, signed URLs
- `docs/{ORY,GOOGLE_SSO,APPLE_SSO,PUSH_NOTIFICATIONS,LOGGING,DEPLOY,ANDROID_RELEASE,RELEASE_NOTES}.md`

## Layout

- `backend/src/` — Worker: `index.ts` (Hono routes), `auth.ts`, `media.ts`, `push.ts`, `util.ts`, `types.ts`
- `backend/migrations/` — D1 schema, numbered SQL files (never edit a prior one; add the next number)
- `mobile/lib/` — `api/api_client.dart`, `screens/`, `state/` (auth, biometric, feed, push), `models/`, `widgets/`, `util/`, `config.dart`, `theme.dart`, `main.dart`
- `Makefile` — daily commands; `make help` for the list

## Hard rules

- Every authenticated route validates `Authorization: Bearer <token>` via Ory `/sessions/whoami`. Don't add an auth bypass.
- All R2 reads go through the Worker's `/media/...` route with an HMAC-signed URL — never hand the client a raw R2 URL.
- Schema changes = a new `backend/migrations/NNNN_<name>.sql`. Never edit a prior migration.
- Mobile HTTP goes through `mobile/lib/api/api_client.dart`, not direct from screens/state.
- Logging uses the helpers in `backend/src/util.ts` / `mobile/lib/util/log.dart` (debug-toggle gated). No bare `console.log`/`print`.
- Match existing patterns in `screens/`, `state/`, and Hono routes — don't introduce a new state lib, HTTP client, or image-cache lib.

## Working rhythm

1. Read the closest existing file and match its shape (route, screen, state class, migration).
2. Migration → Worker route → `api_client.dart` → screen/state. Don't skip the api_client layer.
3. Run `make tc` (typechecks both sides) before reporting done. For UI work, also run `make worker` + `make dev` and verify the flow on the simulator.
4. Native iOS changes (Info.plist, new plugin, icon/splash regen) → tell the user to `make clean && make setup && make dev`.
5. Commit messages use conventional-commit prefixes (`feat:`/`fix:`/`feat!:`) so `make release-note-add` computes the right version bump. Don't hand-edit `docs/RELEASE_NOTES.md`.

## Don't touch without explicit ask

`wrangler secret put`, `make worker-deploy`, `make ship*`, `git push`, anything that writes to prod D1 or uploads a build.
