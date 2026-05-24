// Upload the freshly-built Android AAB to Google Play Console.
//
// Usage:   node scripts/ship-playstore.js [track]
//          track defaults to `internal`. Valid: internal | alpha | beta | production
//
// Reads config from scripts/ship.env (same file as the iOS ship script).
// Required values in ship.env:
//   PLAY_SERVICE_ACCOUNT_JSON   — absolute path to the GCP service-account .json
//   PACKAGE_NAME (optional)     — defaults to cc.lovelinuxalot.familygram
//
// The AAB must already be built at:
//   mobile/build/app/outputs/bundle/release/app-release.aab

import { google } from 'googleapis';
import { readFileSync, createReadStream, statSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import process from 'node:process';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');

function loadEnv(path) {
  if (!statSync(path, { throwIfNoEntry: false })) return;
  const text = readFileSync(path, 'utf8');
  for (const line of text.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const m = trimmed.match(/^([A-Z_][A-Z0-9_]*)\s*=\s*(.*)$/i);
    if (!m) continue;
    let val = m[2].trim();
    if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) {
      val = val.slice(1, -1);
    }
    if (!(m[1] in process.env)) process.env[m[1]] = val;
  }
}

loadEnv(resolve(repoRoot, 'scripts/ship.env'));

const PACKAGE_NAME = process.env.PACKAGE_NAME || 'cc.lovelinuxalot.familygram';
const KEY_FILE = process.env.PLAY_SERVICE_ACCOUNT_JSON;
const AAB_PATH = resolve(repoRoot, 'mobile/build/app/outputs/bundle/release/app-release.aab');
const TRACK = process.argv[2] || 'internal';
// Caller may set RELEASE_NOTES to the body text we want Play Console to show
// users / testers. Play limits this to 500 chars per language; we truncate
// politely. Empty/unset => no release notes are attached.
const RELEASE_NOTES_RAW = (process.env.RELEASE_NOTES ?? '').trim();
const RELEASE_NOTES_LANG = process.env.RELEASE_NOTES_LANG || 'en-US';
const PLAY_MAX = 500;
const RELEASE_NOTES = RELEASE_NOTES_RAW.length > PLAY_MAX
  ? RELEASE_NOTES_RAW.slice(0, PLAY_MAX - 1).trimEnd() + '…'
  : RELEASE_NOTES_RAW;

if (!KEY_FILE) {
  console.error('PLAY_SERVICE_ACCOUNT_JSON not set in scripts/ship.env.');
  console.error('See docs/ANDROID_RELEASE.md for the service-account setup.');
  process.exit(1);
}
if (!statSync(KEY_FILE, { throwIfNoEntry: false })) {
  console.error(`Service-account JSON not found at ${KEY_FILE}`);
  process.exit(1);
}
if (!statSync(AAB_PATH, { throwIfNoEntry: false })) {
  console.error(`AAB not found at ${AAB_PATH}`);
  console.error('Run `make build-android` first.');
  process.exit(1);
}

async function main() {
  const auth = new google.auth.GoogleAuth({
    keyFile: KEY_FILE,
    scopes: ['https://www.googleapis.com/auth/androidpublisher'],
  });
  const androidpublisher = google.androidpublisher({ version: 'v3', auth });

  console.log(`▸ Creating an edit for ${PACKAGE_NAME}…`);
  const edit = await androidpublisher.edits.insert({ packageName: PACKAGE_NAME });
  const editId = edit.data.id;
  if (!editId) throw new Error('edits.insert returned no id');

  console.log(`▸ Uploading ${AAB_PATH}…`);
  const upload = await androidpublisher.edits.bundles.upload({
    packageName: PACKAGE_NAME,
    editId,
    media: {
      mimeType: 'application/octet-stream',
      body: createReadStream(AAB_PATH),
    },
  });
  const versionCode = upload.data.versionCode;
  if (!versionCode) throw new Error('bundle upload returned no versionCode');
  console.log(`▸ Uploaded versionCode ${versionCode}`);

  console.log(`▸ Assigning versionCode ${versionCode} to track "${TRACK}"…`);
  const release = {
    status: 'completed',
    versionCodes: [String(versionCode)],
  };
  if (RELEASE_NOTES) {
    release.releaseNotes = [{ language: RELEASE_NOTES_LANG, text: RELEASE_NOTES }];
    console.log(`▸ Attaching release notes (${RELEASE_NOTES.length} chars, ${RELEASE_NOTES_LANG}).`);
  }
  await androidpublisher.edits.tracks.update({
    packageName: PACKAGE_NAME,
    editId,
    track: TRACK,
    requestBody: { releases: [release] },
  });

  console.log('▸ Committing edit…');
  await androidpublisher.edits.commit({ packageName: PACKAGE_NAME, editId });

  console.log('');
  console.log(`✅ Familygram versionCode ${versionCode} live on Play Console track "${TRACK}"`);
  console.log('   Internal testers see the update in ~5 min via the TestFlight-style notification.');
}

main().catch((err) => {
  console.error('upload failed:', err?.errors || err?.message || err);
  process.exit(1);
});
