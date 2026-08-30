#!/usr/bin/env node
// Preflight: fail before `flutter build appbundle` if pubspec's build number
// is one Play Console has already seen.
//
// Why this exists: the versionCode is baked into the AAB at build time, and
// `ship-testflight.sh` bumps mobile/pubspec.yaml but does NOT commit it — it
// only prints a reminder. Skip that commit once and git's build number drifts
// behind what was actually uploaded, so the next ship rebuilds a versionCode
// Play already holds and is rejected *after* a multi-minute 49MB build.
// Checking first turns that into an instant, explanatory failure.
//
// Read-only: lists existing versionCodes via an edit that is always discarded.

import { google } from 'googleapis';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import process from 'node:process';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const PUBSPEC = resolve(repoRoot, 'mobile/pubspec.yaml');

function loadEnv(file) {
  for (const line of readFileSync(file, 'utf8').split('\n')) {
    const m = line.match(/^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)\s*=\s*(.*)\s*$/);
    if (!m) continue;
    let val = m[2].trim();
    if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) {
      val = val.slice(1, -1);
    }
    if (!(m[1] in process.env)) process.env[m[1]] = val;
  }
}

async function main() {
  loadEnv(resolve(repoRoot, 'scripts/ship.env'));
  const PACKAGE_NAME = process.env.PACKAGE_NAME || 'cc.lovelinuxalot.familygram';
  const KEY_FILE = process.env.PLAY_SERVICE_ACCOUNT_JSON;

  const pubspec = readFileSync(PUBSPEC, 'utf8');
  const m = pubspec.match(/^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)\s*$/m);
  if (!m) {
    console.error('✘ Could not parse `version: x.y.z+build` from mobile/pubspec.yaml');
    process.exit(2);
  }
  const versionName = m[1];
  const local = Number(m[2]);

  if (!KEY_FILE) {
    console.log('▸ PLAY_SERVICE_ACCOUNT_JSON not set — skipping versionCode preflight.');
    return;
  }

  let used = [];
  try {
    const auth = new google.auth.GoogleAuth({
      keyFile: KEY_FILE,
      scopes: ['https://www.googleapis.com/auth/androidpublisher'],
    });
    const ap = google.androidpublisher({ version: 'v3', auth });
    const edit = await ap.edits.insert({ packageName: PACKAGE_NAME });
    const editId = edit.data.id;
    try {
      const bundles = await ap.edits.bundles.list({ packageName: PACKAGE_NAME, editId });
      used = (bundles.data.bundles || []).map((b) => Number(b.versionCode));
    } finally {
      await ap.edits.delete({ packageName: PACKAGE_NAME, editId }).catch(() => {});
    }
  } catch (e) {
    // A network blip or an expired key must not block a release: warn and let
    // the upload be the authority, exactly as before this check existed.
    console.log(`▸ versionCode preflight skipped (could not reach Play): ${e?.message ?? e}`);
    return;
  }

  const highest = used.length ? Math.max(...used) : 0;
  if (used.includes(local) || local <= highest) {
    console.error('');
    console.error(`✘ versionCode ${local} cannot be uploaded.`);
    console.error(`  mobile/pubspec.yaml says ${versionName}+${local}`);
    console.error(`  Play already has versionCode(s): ${used.sort((a, b) => a - b).join(', ') || 'none'}`);
    console.error('');
    console.error(`  Set the build number to ${highest + 1} or higher:`);
    console.error(`      version: ${versionName}+${highest + 1}`);
    console.error('');
    console.error('  This usually means a previous ship bumped pubspec.yaml but the bump was');
    console.error('  never committed. After shipping, run:');
    console.error('      git add mobile/pubspec.yaml docs/RELEASE_NOTES.md && git commit -m "release: <version>"');
    console.error('');
    process.exit(1);
  }

  console.log(`▸ versionCode ${local} is free (Play's highest is ${highest || 'none'}).`);
}

main().catch((err) => {
  console.error('versionCode preflight failed:', err?.errors || err?.message || err);
  process.exit(1);
});
