# Ship to TestFlight

One script. Run it every ~80 days (or whenever you ship a feature) to keep the family's TestFlight build alive.

```bash
./scripts/ship-testflight.sh
```

That's the goal. To get there, do the one-time setup below first.

---

## One-time setup

### 1. Apple Developer Program

Enroll at https://developer.apple.com/programs/ ($99/year). 24-48 hours for individual verification.

### 2. App Store Connect — create the app record

After enrollment:

1. https://appstoreconnect.apple.com → **My Apps** → **+** → **New App**.
2. Platform: **iOS**.
3. Name: `Familygram`.
4. Primary language: English (US) or yours.
5. Bundle ID: pick your unique one (e.g. `cc.lovelinuxalot.familygram.allan`). Must match the one in `ios/Runner.xcodeproj/project.pbxproj`.
6. SKU: anything unique to your account, e.g. `familygram-1`.
7. Save.

### 3. App Store Connect — create an API key

This is what the upload script authenticates with. **One key**, used for every release.

1. https://appstoreconnect.apple.com/access/integrations/api → **Keys** → **+**.
2. Name: `Familygram CLI release`.
3. Access: **App Manager** (or **Developer** if you want minimum privilege).
4. **Generate**. Apple shows the key **only once** — download the `.p8` file immediately.
5. Note the **Key ID** (10 chars, e.g. `ABCDE12345`) and **Issuer ID** (UUID).
6. Move the `.p8` to:

   ```bash
   mkdir -p ~/.appstoreconnect/private_keys
   mv ~/Downloads/AuthKey_*.p8 ~/.appstoreconnect/private_keys/
   ```

   `xcrun altool` looks here by default.

### 4. Configure the local script

```bash
cp scripts/ship.env.example scripts/ship.env
chmod +x scripts/ship-testflight.sh
```

Edit `scripts/ship.env` and fill in:
- `API_BASE` — the URL `wrangler deploy` printed for your production Worker.
- `ASC_API_KEY_ID` and `ASC_API_ISSUER_ID` from step 3.

`scripts/ship.env` is gitignored, so secrets stay on your laptop.

### 5. Xcode — production signing

1. Open `mobile/ios/Runner.xcworkspace` in Xcode.
2. **Runner** target → **Signing & Capabilities**.
3. Team: select your **paid** Apple Developer account (now shows your name without "(Personal Team)").
4. Bundle Identifier: same one you used in App Store Connect step 2.
5. Save.

### 6. First archive (sanity check)

Before the script can upload, you want to do the first archive in Xcode to confirm signing works end-to-end:

1. Xcode → top bar → set target to **Any iOS Device (arm64)**, not a simulator.
2. **Product → Archive** (takes a few minutes).
3. Window that pops up → **Distribute App** → **TestFlight & App Store** → **Upload**. Apple processes and the build shows up in App Store Connect → TestFlight in 5-15 min.

Once that's worked once, every subsequent release is `./scripts/ship-testflight.sh`.

---

## Recurring release

```bash
./scripts/ship-testflight.sh
```

The script:
1. Bumps the build number in `mobile/pubspec.yaml` (semver stays the same).
2. Runs `flutter build ipa --release` with the prod dart-defines from `ship.env`.
3. Validates the IPA with `altool`.
4. Uploads to App Store Connect.
5. Prints the version it shipped and reminds you to commit the bump.

5-15 minutes after the script finishes, the build appears in App Store Connect → TestFlight. Internal testers get it immediately. External testers see it after Apple's beta review (often within hours for subsequent builds).

---

## Calendar / reminder strategy

Three options to remember the 80-day cycle:

1. **macOS Calendar repeating event** — set "Release Familygram to TestFlight" every 80 days. Lowest tech, works fine.
2. **launchd plist** — auto-runs the script. But the script wants the keychain unlocked and may want you to babysit a prompt; not recommended for set-and-forget.
3. **App Store proper** — submit once, never deal with expiry again. Best long-term answer for a stable app.

---

## Troubleshooting

**"No identity matching the bundle identifier was found"** — Xcode signing isn't set up yet. Repeat step 5.

**"Failed to authenticate for upload"** — wrong API key, wrong issuer ID, or the `.p8` file isn't in `~/.appstoreconnect/private_keys/`.

**"This bundle is invalid"** — build number must be strictly greater than the previous upload. The script auto-bumps from `pubspec.yaml`, but if pubspec was reset somehow, manually edit `version: 0.1.0+N` to a number above what App Store Connect already has.

**Build sticks at "Processing" for > 1 hour** — sometimes Apple's backend is slow. Just wait. If still stuck after 24 hours, check email for an Apple-side rejection.
