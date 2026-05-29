# Push notifications

How Familygram delivers a notification to every family member when someone
uploads a new post. Worker fans out via FCM HTTP v1; iOS receives via APNs
(proxied through Firebase), Android receives directly through FCM.

You only need to run through this once per deployment. After that, the
Worker fan-out and the Flutter token-registration handle themselves.

---

## What you'll end up with

```
              ┌────────────────────────┐
   upload ──▶ │  POST /posts (Worker)  │ ──┐
              └────────────────────────┘   │ executionCtx.waitUntil
                                           ▼
                                 ┌──────────────────┐
                                 │  device_tokens   │ ◀── /me/device-tokens
                                 │  (D1)            │     (Flutter on login)
                                 └──────────────────┘
                                           │
                                           ▼
                       ┌─────────────────────────────────────────┐
                       │   FCM HTTP v1 (oauth2.googleapis.com)   │
                       └─────────────────────────────────────────┘
                                   │                │
                               iOS │                │ Android
                                   ▼                ▼
                                 APNs            FCM
                                   │                │
                                   ▼                ▼
                          ┌──────────────┐  ┌──────────────┐
                          │ iPhone       │  │ Android      │
                          └──────────────┘  └──────────────┘
```

---

## 1. Create the Firebase project

In the [Firebase console](https://console.firebase.google.com):

1. **Add project** → pick a name (e.g. `familygram-yourhandle`).
2. Disable Google Analytics — not needed for push, just adds permissions.
3. Hit **Create project**.

---

## 2. Register the iOS app

In the project home, click the **iOS+** icon (or **Add app → Apple**).

- **Apple bundle ID**: `cc.lovelinuxalot.familygram` (match
  `PRODUCT_BUNDLE_IDENTIFIER` in `mobile/ios/Runner.xcodeproj/project.pbxproj`)
- **App nickname**: cosmetic; `Familygram iOS` is fine
- **App Store ID**: leave blank
- **Register app** → **Download GoogleService-Info.plist**

Drop the file at:
```
mobile/ios/Runner/GoogleService-Info.plist
```

Then in Xcode (`open mobile/ios/Runner.xcworkspace`):

1. Drag the file into the Project navigator under the **Runner** folder,
   check **"Copy items if needed"** + **"Add to target: Runner"**.
2. Verify it appears in **Runner target → Build Phases → Copy Bundle
   Resources**.
3. **Runner target → Signing & Capabilities → + Capability**:
   - **Push Notifications**
   - **Background Modes** → check **Remote notifications**

Skip the "Add Firebase SDK" / "Initialization code" screens — the
`firebase_core` Flutter plugin handles that.

---

## 3. Register the Android app

Back in the Firebase console: **Add app → Android**.

- **Android package name**: `cc.lovelinuxalot.familygram` (match
  `applicationId` in `mobile/android/app/build.gradle.kts`)
- **App nickname**: `Familygram Android`
- **SHA-1**: leave blank — not needed because we don't use Firebase Auth
- **Register app** → **Download google-services.json**

Drop the file at:
```
mobile/android/app/google-services.json
```

The gradle plugin wiring is already committed in
`mobile/android/settings.gradle.kts` and `mobile/android/app/build.gradle.kts`,
so no native code change is needed.

---

## 4. Upload your APNs auth key

Without this step, iOS notifications silently fail to deliver. You need a
single `.p8` "auth key" from Apple — it works for sandbox **and**
production, never expires, and one key covers every app under the same
team.

**In [Apple Developer](https://developer.apple.com)** → Certificates,
Identifiers & Profiles → **Keys** (sidebar, *not* Certificates):

1. **+** to register a new key
2. **Key Name**: `Familygram APNs` (anything)
3. Check **Apple Push Notifications service (APNs)**
4. Continue → Register → **Download** the `.p8` (you can only download
   it once; store safely)
5. Note the **Key ID** (10 chars, shown on the page) and your **Team ID**
   (10 chars, top-right of the Apple Developer site)

**Back in Firebase console**:

- Gear icon → **Project settings** → **Cloud Messaging** tab
- Under **Apple app configuration** → **APNs Authentication Key** →
  **Upload**
- Upload the `.p8`, paste **Key ID** and **Team ID**

---

## 5. Generate the service account JSON for the Worker

The Cloudflare Worker authenticates to FCM with a service-account JWT.

- Gear icon → **Project settings** → **Service accounts** tab
- **Generate new private key** → confirm **Generate key**
- A JSON file downloads. Do not commit it.

Set the Worker secrets (the secret name `FCM_SERVICE_ACCOUNT_JSON` must
match what the code reads in `backend/src/types.ts`):

```bash
cd backend

# Pipe the file in so you don't have to paste a multi-line JSON.
cat ~/Downloads/your-firebase-adminsdk-*.json | \
  npx wrangler secret put FCM_SERVICE_ACCOUNT_JSON -c wrangler.local.jsonc

# project_id is one of the fields inside that JSON.
jq -r '.project_id' ~/Downloads/your-firebase-adminsdk-*.json | \
  npx wrangler secret put FCM_PROJECT_ID -c wrangler.local.jsonc
```

Verify with `npx wrangler secret list -c wrangler.local.jsonc` — both
names should be in the output.

> **Heads-up**: plain `npx wrangler secret put ...` defaults to
> `wrangler.jsonc` (the committed template, with `"name": "your-worker-name"`)
> and will offer to create a new Worker by that name. Always pass
> `-c wrangler.local.jsonc`.

---

## 6. Apply the D1 migration

```bash
make worker-migrate-prod
```

This adds the `device_tokens` table. The Worker won't be able to register
tokens until this lands.

---

## 7. Deploy the Worker

```bash
make worker-deploy
```

---

## 8. Build & ship the mobile app

Push capabilities and Firebase initialization changed native code, so the
build needs to be regenerated and re-uploaded. After this point, anyone
running an older TestFlight / internal-testing build will not receive
notifications.

```bash
make clean && make setup
make ship VERSION=<next>      # both platforms
# or
make ship-ios VERSION=<next>
make ship-android
```

---

## How it works at runtime

- **Login**: `auth.dart` calls `pushController.onAuthenticated()` after
  `_resolveUser` succeeds. That requests notification permission, waits
  for the APNs token (iOS only), gets the FCM token, and POSTs it to
  `/me/device-tokens`.
- **Upload**: `POST /posts` inserts the post row, then schedules
  `fanOutNewPost(...)` via `c.executionCtx.waitUntil` so the response
  isn't blocked. Fan-out queries `device_tokens WHERE user_id != author`,
  sends one FCM request per token in parallel, prunes any tokens FCM
  marks `UNREGISTERED` or `INVALID_ARGUMENT`.
- **Tap a notification** (cold-start, background, or foreground on
  Android via `flutter_local_notifications`): `push.dart`'s `_handleTap`
  reads `message.data.post_id` and calls `router.push('/post/$id')`.
- **Logout**: unregisters the current device token from D1 before
  clearing the session.
- **Reinstall / token rotation**: FCM emits `onTokenRefresh`; the
  controller re-POSTs to `/me/device-tokens` (the endpoint upserts on
  the token PK).

## What happens without FCM configured

If `FCM_SERVICE_ACCOUNT_JSON` or `FCM_PROJECT_ID` is unset, the Worker
logs `push: FCM not configured, skipping` and the fan-out no-ops. The
rest of the app — uploads, feed, comments, likes — works unchanged. This
is the local-dev default.

## Notification payload

Familygram sends four push types. All four have the same shape:

- **Title**: the actor's `display_name` (poster or commenter).
- **Body**: short, recipient-specific copy (see table below).
- **Data**: `{ post_id, type, ... }`. The mobile tap handler reads
  `post_id` to deep-link to `/post/<id>`.

| `data.type`             | Source           | Sent to                                                | Body                                                       |
|-------------------------|------------------|--------------------------------------------------------|------------------------------------------------------------|
| `new_post`              | new post upload  | family members except the author and @mentioned users  | caption (truncated to 140) or `"shared a new photo"`        |
| `mention`               | post caption     | each `@mentioned` user (not the author)                | `mentioned you in their post`                              |
| `new_comment`           | new comment      | post author (when not @mentioned in the comment)       | `commented on your post`                                   |
| `mention`               | comment body     | each `@mentioned` user (not the commenter, not the post author) | `mentioned you in a comment`                               |
| `comment_with_mention`  | new comment      | post author **when they're also @mentioned**           | `commented on your post and mentioned you`                 |

A single post or comment results in **at most one push per recipient** —
the fan-out buckets recipients so that an @mentioned user gets the
mention notification *instead of* the generic post broadcast, and the
post author of a commented-on-and-mentioned post gets
`comment_with_mention` rather than two separate pushes. The actor (poster
or commenter) never gets their own push.

`mention` covers both post-caption and comment-body mentions. The two
are distinguished by `data.comment_id`: present on comment mentions,
absent on post mentions. `data.comment_id` is also reserved for future
"scroll to this comment" deep-linking; today the tap handler ignores it
and just opens the post.

Captions and comment snippets show on the lock screen — keep that in
mind for the family.

To change the body of a particular type, edit `fanOutNewPost` or
`fanOutNewComment` in `backend/src/index.ts`.

## Debugging tips

See [docs/LOGGING.md](LOGGING.md) for the full toggle / what-shows-where
reference. The push-specific basics are below.

- **Worker logs**: `cd backend && npx wrangler tail -c wrangler.local.jsonc`
  shows every `POST /posts` and the inner `push: ...` lines. Toggle verbose
  mode with `echo 1 | npx wrangler secret put DEBUG_LOGGING -c wrangler.local.jsonc`
  (and `secret delete` to turn off).
- **Token didn't register**: check `Authorization` was set on the
  `/me/device-tokens` POST. The mobile client only registers AFTER
  `_resolveUser` succeeds — if you signed in but the allowlist rejected
  you, no token is registered.
- **Push not received on iOS**: verify the device is on Wi-Fi or cellular
  (APNs needs network), the app is built with the right provisioning
  profile (Push capability requires the bundle ID's App ID to have Push
  enabled in Apple Developer), and `aps-environment` is in
  `mobile/ios/Runner/Runner.entitlements`.
- **Push not received on Android**: confirm `google-services.json` is
  inside `mobile/android/app/`, and the device has Google Play Services
  installed (FCM requires it).
- **Simulator / emulator**: iOS simulator can receive APNs in Xcode 14+
  via drag-and-drop of an `.apns` file but won't receive real push.
  Android emulators with Google APIs *do* receive FCM. Real devices are
  the reliable path.
