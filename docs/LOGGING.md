# Logging & debug toggle

Familygram has a single switch — the Worker secret `DEBUG_LOGGING` — that
controls verbose logging across **both the Worker and the iOS/Android app**.
Toggle it without redeploying anything; errors are never silenced.

---

## TL;DR

```bash
cd backend

# Turn ON (verbose: request logs + push fan-out details + client diag POSTs)
echo 1 | npx wrangler secret put DEBUG_LOGGING -c wrangler.local.jsonc

# Turn OFF (errors + warnings only)
npx wrangler secret delete DEBUG_LOGGING -c wrangler.local.jsonc

# Confirm (substitute your own Worker host)
curl -sS https://<your-worker>.<your-handle>.workers.dev/config
# → {"demo_mode":false,"debug":true}    (or "debug":false when off)
```

Either takes effect within seconds, no build, no deploy. The mobile app
picks up the flag at the next app launch (force-quit + reopen).

---

## Where logs go

| Source | Stream | View it with |
|---|---|---|
| Worker (Hono request log, push fan-out, `push-diag` payloads) | Cloudflare logs | `cd backend && npx wrangler tail -c wrangler.local.jsonc` |
| Worker errors (`console.error`) | Cloudflare logs | same |
| iOS app — `flog(...)` lines | iOS device console | Mac + USB cable + **Console.app** → select iPhone in sidebar → filter "familygram" |
| iOS app — `print(...)` during local dev | Xcode Run console | `flutter run` (debug build) |
| Android app — `flog(...)` lines | Android device log | `adb logcat | grep familygram` |

---

## What the flag gates

### Gated (only logged when `DEBUG_LOGGING` is set)

| Line | Source |
|---|---|
| `<-- GET /me` / `--> GET /me 200 138ms` | `backend/src/index.ts` (Hono request logger) |
| `push: fan-out post=... author=... recipients=N` | `backend/src/index.ts` (post upload) |
| `push: sent=N invalid=N post=...` | `backend/src/index.ts` (after FCM batch) |
| `push: skipping fan-out — demo author ...` | `backend/src/index.ts` (demo author guard) |
| `push-diag user=... {"stage":"...","..."}` | `backend/src/index.ts` (`/me/push-diagnostic` endpoint) |
| `[familygram] push-diag {...}` | `mobile/lib/state/push.dart` (via `flog`) |
| `[familygram] push: register token failed: ...` | same |
| `[familygram] push: permission denied; skipping registration` | same |
| Diagnostic POSTs to `/me/push-diagnostic` from the iOS app | `mobile/lib/state/push.dart` (skipped client-side when off — saves bandwidth) |

### Never gated (always on)

| Line | Why |
|---|---|
| `console.error(...)` for FCM send failures, OAuth errors, unhandled exceptions | Real failures should always be visible |
| `push: FCM not configured, skipping` | One-time misconfiguration warning |
| Cloudflare's own per-request line (`GET https://... - Ok @ ...`) | Platform-level, can't be controlled by Worker code |
| `debugPrint('Firebase init failed; ...')` in `main.dart` | Fires before `/config` is fetched, can't be gated by it |

---

## Operating model

### Server (Worker)

- Reads `env.DEBUG_LOGGING` on **every request** via the `isDebugEnabled(env)`
  helper in `backend/src/types.ts`.
- Truthy values (`1`, `true`, `yes`, `on`, case-insensitive) → on. Unset, empty,
  or `0` → off.
- A `wrangler secret put` / `secret delete` propagates within seconds. No
  redeploy needed.

### Client (Flutter)

- `main.dart` calls `ApiClient().fetchConfig()` at app startup (right after
  `Firebase.initializeApp()`). Stores the `debug` flag in a global
  (`mobile/lib/util/log.dart`).
- `flog(...)` checks the global on every call. Off = cheap no-op; on =
  `print(...)` which survives release builds and shows up in
  Console.app / adb logcat.
- The diagnostic POSTs to `/me/push-diagnostic` are also gated client-side,
  so when debug is off the iPhone doesn't waste a network round-trip on each
  push registration step.
- The flag is fetched **once at app launch**. Toggling the server flag while
  the app is running won't take effect until the user **force-quits and
  reopens** the app. Acceptable for debug sessions.

### Failure-mode

- If `/config` is unreachable at startup, the client defaults to **debug
  off** (the quiet path). Errors still log server-side via `console.error`,
  so visibility into actual failures is never lost.

---

## Recipes

### Diagnose a push registration on iOS

```bash
# Terminal 1
cd backend
echo 1 | npx wrangler secret put DEBUG_LOGGING -c wrangler.local.jsonc
npx wrangler tail -c wrangler.local.jsonc
```

On the iPhone: force-quit Familygram → reopen → sign in if needed. You'll
see a sequence of `push-diag` lines showing the stages
(`initOnce.start` → `requestPermission` → `apnsToken` → `fcmToken` →
`registered`). The last stage that appears is where it broke.

When done:

```bash
npx wrangler secret delete DEBUG_LOGGING -c wrangler.local.jsonc
```

### Diagnose a fan-out (notifications aren't arriving)

With `DEBUG_LOGGING` on:

```
POST /posts ...
push: fan-out post=abc123 author=def456 recipients=3
push: sent=3 invalid=0 post=abc123
```

- `recipients=0` → no device tokens registered (check
  `device_tokens` table or sign in on a second device).
- `invalid=N` non-zero → FCM rejected N tokens as unregistered/malformed;
  they've been pruned. Re-run after the next sign-in on the affected device.
- Neither line appears → something earlier threw; look for a `fanOutNewPost
  failed ...` error line right above.

### See actual device-side errors on iPhone

Requires a Mac with the iPhone plugged in:

1. Open **Console.app** on the Mac.
2. Click your iPhone in the left sidebar (under "Devices").
3. In the search bar at the top, filter `familygram`.
4. With `DEBUG_LOGGING` on, force-quit and reopen the app.
5. You'll see `[familygram] ...` lines from `flog()` plus iOS-level
   APNs / Firebase logs interleaved.

---

## Adding new debug-only logs

### Server (`backend/src/`)

```ts
import { isDebugEnabled } from './types';

if (isDebugEnabled(c.env)) {
  console.log(`my-debug-line: ${something}`);
}
```

Or for errors (always logged):

```ts
console.error('something bad happened', err);
```

### Client (`mobile/lib/`)

```dart
import 'package:familygram/util/log.dart' as logutil;

logutil.flog('my-debug-line: $something');
```

Don't use `debugPrint` for things you might want to see on TestFlight —
it's stripped from release builds. `flog` survives release builds and
no-ops cheaply when the flag is off.
