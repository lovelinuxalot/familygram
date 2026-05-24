# Android release

How to get Familygram on the Google Play Store, for testing and eventually production.

Time budget: ~30 min hands-on + ~24 h waiting on Google Play Console verification (first time only).

The auth flow you set up for iOS already works for Android — we use Ory's OIDC web flow (not Google's native SDK), so there's **no new Google Cloud OAuth client** to create. The same web OAuth that backs iOS Google sign-in works on Android via Chrome Custom Tabs.

---

## 1. Generate the upload keystore

This is your private signing key. Lose it and you can't ship updates ever again (Play Store won't accept builds signed with a different key). Generate once, back it up.

```bash
cd /Users/allan.john/personal/git/familygram/mobile/android
keytool -genkey -v \
  -keystore upload-keystore.jks \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -alias upload
```

You'll be prompted for:
- **Keystore password**: pick a strong one.
- **Key password**: can be the same as keystore password.
- **Name / org / etc**: anything reasonable (your name, country code).
- Confirm with `yes`.

Result: `mobile/android/upload-keystore.jks` (already gitignored).

**Back this file up** — copy it to your password manager, a USB drive, anything safe. Without it you cannot release updates.

Then create the secrets file Gradle reads at build time:

```bash
cd /Users/allan.john/personal/git/familygram/mobile/android
cat > key.properties <<EOF
storePassword=<the keystore password you just set>
keyPassword=<the key password>
keyAlias=upload
storeFile=upload-keystore.jks
EOF
```

`key.properties` is also gitignored.

---

## 2. Build a release AAB

The Android App Bundle (`.aab`) is what Play Store wants — not a raw APK.

```bash
cd /Users/allan.john/personal/git/familygram
make build-android
```

This sources prod URLs from `scripts/ship.env` and runs `flutter build appbundle --release`. Output:

```
mobile/build/app/outputs/bundle/release/app-release.aab
```

To smoke-test the AAB locally, install with `bundletool` (or just `flutter run --release` on a connected Android device).

---

## 3. Google Play Console account (one-time)

1. https://play.google.com/console/signup
2. Sign in with a Google account you control (this is your developer identity — pick one you'll keep).
3. **Developer account type**: Individual or Organization, your choice.
4. Pay the **$25 one-time fee** with a credit card.
5. Google verifies your identity. Usually a few hours; occasionally up to 48 hours.

You'll get an email when you're verified. Continue with steps 4+ after.

### 3a. Identity verification gotcha — Play Console app requires Android 10+

Partway through signup, Google asks you to install the **Google Play Console** app on an Android device and complete the identity check there. The Console app requires Android 10+. If your device is older (e.g. a Note 8 stuck on Android 9), you have two options.

**A. Third-party Android emulator (what worked)** — [MuMu Player](https://www.mumuplayer.com) on Mac. It ships with Play Store built in, presents itself as a real-ish device, and passed Google's identity check where the official Android SDK emulator was rejected. Free.

1. Download and install MuMu Player for Mac.
2. Boot the default Android profile.
3. Open Play Store → sign in with your developer Google account.
4. Install **Google Play Console**.
5. Open Play Console → run identity verification.

**B. Borrow a real Android 10+ device** for 15 minutes from anyone (family member, friend). Verification is one-time — you don't need to keep the device after.

---

## 4. Create the app in Play Console

1. Play Console → **Create app**.
2. Fill in:
   - **App name**: `Familygram`. (Play Store names are *not* required to be globally unique — unlike Apple — so the plain name works.)
   - **Default language**: English (US) or yours.
   - **App or game**: App.
   - **Free or paid**: Free.
   - Confirm the declarations (apps, terms, etc.).
3. **Create app**.

After creation, when Play Console asks for the **Package name** (sometimes during the first AAB upload rather than at creation), use the exact value from `mobile/android/app/build.gradle.kts`:

```
cc.lovelinuxalot.familygram
```

This must match Apple's bundle ID setup and is **permanent** — every future upload must use this same package name, and you can't change it later without creating a new Play Store listing.

You'll land on the dashboard with a long checklist. Don't fill out the whole thing yet — just enough to get into Internal Testing.

---

## 5. Upload your first AAB to Internal Testing

This track doesn't require a Play Console review; builds are available to testers within ~5 minutes of upload.

1. Left sidebar → **Test and Release → Testing → Internal testing**.
2. **Create new release**.
3. **App integrity** → **Use Play App Signing** (the default — Google handles the actual release signing, you only need the upload key from step 1).
4. **App bundles** → drag `app-release.aab` in.
5. **Release name**: `1.1.0 (2)` (matches `pubspec.yaml`).
6. **Release notes**: copy from `docs/RELEASE_NOTES.md` v1.1.0 — Play Console accepts plain text.
7. **Save** → **Review release** → **Start rollout to Internal testing**.

The first time, you also need to fill in:
- **App content** in the left sidebar → app category, content rating questionnaire, target audience, privacy policy URL (your Worker's `/privacy` route — `https://<your-worker>.<your-cf-handle>.workers.dev/privacy`), data safety form, news app declaration.

It looks like a lot but most are single-page forms with yes/no questions. ~20 min total. Required only once unless answers change.

---

## 6. Add internal testers

1. Internal testing → **Testers** tab → **Create email list**.
2. Add your own Gmail and any family members' Gmails. Up to 100 testers.
3. Save.
4. Each tester gets an email with a Play Store link. Tap it on their Android device → install Familygram from Play Store → sign in with Google.

Allowlist them in Familygram's admin panel (using whatever email they signed into Familygram with).

---

## 7. Automate uploads (one-time setup, ~15 min)

After this section, `make ship-android` builds the AAB and uploads it to Play Console automatically — same one-command flow as iOS TestFlight.

### 7a. Enable the Google Play Android Developer API (must do this first)

The service account in 7b can't call Play Console until the API is enabled on your GCP project. Do this **before** creating the service account — otherwise the JSON key you download authenticates against an API that isn't turned on, and uploads fail with a 403.

1. https://console.cloud.google.com — make sure the project picker (top bar) shows the **same project** you used for the Google sign-in OAuth client. If you skipped Google sign-in, pick any project; create a new one if needed.
2. **APIs & Services → Library** → search for **"Google Play Android Developer API"** → click it → **Enable**.
3. Wait ~30 seconds for activation. The page should say "API enabled".

### 7b. Create a service account

(Now that the API is enabled in 7a.)

1. https://console.cloud.google.com → **IAM & Admin → Service Accounts** → **+ Create service account**. Confirm the project picker shows the same project you enabled the API on.
2. Service account details:
   - Name: `Familygram Play release`
   - ID: anything reasonable (e.g. `familygram-play`)
3. Skip the "Grant access" steps (we grant access in Play Console next). Click **Done**.
4. Click the newly-created service account → **Keys** tab → **Add Key → Create new key → JSON**. A `.json` file downloads. **Save it somewhere safe** — this is the credential the upload uses.
5. Note the service account email — looks like `familygram-play@<project>.iam.gserviceaccount.com`.

### 7c. Grant the service account Play Console access

1. https://play.google.com/console → **Users and permissions** (left sidebar).
2. **Invite new users** → paste the service account email.
3. **App permissions** → check Familygram.
4. **Account permissions** → at minimum: **Release manager**. Or limit to "Release apps to testing tracks" if you want to require manual promotion to production.
5. **Invite user**.

(Service accounts auto-accept the invite — no email confirmation needed.)

### 7d. Wire it into ship.env

Add to `scripts/ship.env`:

```sh
PLAY_SERVICE_ACCOUNT_JSON="/absolute/path/to/the/downloaded/key.json"
```

`scripts/ship.env` is gitignored. The JSON file should also live somewhere outside the repo — typically `~/.familygram/play-service-account.json` works well.

---

## 8. Releasing — one command for both platforms

```bash
make ship VERSION=1.2.0
```

- **iOS**: bumps pubspec, builds IPA, uploads to TestFlight.
- **Android**: builds AAB at the same version, uploads to Play Console Internal testing.

Internal testers see the new build within ~5 minutes on both stores.

Or one platform at a time:

```bash
make ship-ios     VERSION=1.2.0          # iOS only
make ship-android                         # Android only — internal testing track
make ship-android TRACK=production        # promote to public production
```

`make build` (without uploading) is also available for both.

---

## Troubleshooting

**`flutter build appbundle` fails with "Keystore file not found"** — the `key.properties` path is relative to `android/`. Verify `upload-keystore.jks` is right next to `key.properties` in `mobile/android/`.

**Play Console: "Your bundle was signed with the same key as the upload key"** — that's fine; Play Console wraps it with their own release key. Ignore.

**Google sign-in opens browser but never returns to app** — the `familygram://` URL scheme isn't registered. Confirm `AndroidManifest.xml` has the `CallbackActivity` block (see file).

**App opens but "Continue with Google" does nothing** — most likely you're using a debug build without the keystore. Try a clean rebuild:
```bash
make clean && make setup
flutter build appbundle --release ...
```

**Tester clicks the install link but Play Store says "Item not available in your country"** — Play Console default visibility is "Available in your country only" — change in Internal testing → Countries/regions to add more.

**Tester is on iOS** — that's TestFlight, not Play. They use the Apple flow.

**`make ship-android` errors with `403 SERVICE_DISABLED` or "Google Play Android Developer API has not been used in project …"** — the API isn't enabled on the GCP project. Go to §7a and enable it. Wait ~30 seconds after enabling for it to propagate, then retry.

**`make ship-android` errors with `401 The current user has insufficient permissions`** — the service account email isn't in Play Console → Users and permissions, or doesn't have a release-related permission. Redo §7c.

**Upload says "Version code N has already been used"** — the AAB's versionCode (auto-bumped from `pubspec.yaml` build number when running `make ship`) collides with a previous upload. Either bump again (`make ship VERSION=…`) or, if iOS is also already at this version, manually edit `mobile/pubspec.yaml` to a higher `+N` build number before retrying.
