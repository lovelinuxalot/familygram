// Poll App Store Connect for the freshly-uploaded build, then attach
// "What's New" text via betaBuildLocalizations.
//
// Apple's altool uploads the binary, but the build takes 5–15 min to
// finish processing before it's queryable. This script polls until the
// build shows up (or times out) and then POSTs the localization.
//
// Usage:
//   node scripts/set-testflight-notes.js <bundleId> <versionString> <buildNumber>
//
// Required env (sourced from scripts/ship.env by the caller):
//   ASC_API_KEY_ID, ASC_API_ISSUER_ID  — already used by ship-testflight.sh
//   RELEASE_NOTES                       — body to set as whatsNew
//
// Reads the private key from ~/.appstoreconnect/private_keys/AuthKey_<ID>.p8.

import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { homedir } from 'node:os';
import jwt from 'jsonwebtoken';
import process from 'node:process';

const [, , BUNDLE_ID, VERSION_STRING, BUILD_NUMBER] = process.argv;
if (!BUNDLE_ID || !VERSION_STRING || !BUILD_NUMBER) {
  console.error('usage: set-testflight-notes.js <bundleId> <versionString> <buildNumber>');
  process.exit(2);
}

const KEY_ID = process.env.ASC_API_KEY_ID;
const ISSUER_ID = process.env.ASC_API_ISSUER_ID;
const NOTES = (process.env.RELEASE_NOTES || '').trim();

if (!KEY_ID || !ISSUER_ID) {
  console.error('Missing ASC_API_KEY_ID / ASC_API_ISSUER_ID in env (load via scripts/ship.env).');
  process.exit(1);
}
if (!NOTES) {
  // Nothing to push — silently exit so callers can no-op.
  console.log('(no RELEASE_NOTES — skipping TestFlight whatsNew update)');
  process.exit(0);
}

const KEY_PATH = resolve(homedir(), '.appstoreconnect/private_keys', `AuthKey_${KEY_ID}.p8`);
const PRIVATE_KEY = readFileSync(KEY_PATH, 'utf8');

function mintToken() {
  return jwt.sign(
    { iss: ISSUER_ID, aud: 'appstoreconnect-v1' },
    PRIVATE_KEY,
    { algorithm: 'ES256', header: { kid: KEY_ID, typ: 'JWT' }, expiresIn: '15m' },
  );
}

async function asc(path, init = {}) {
  const r = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${mintToken()}`,
      'Content-Type': 'application/json',
      ...init.headers,
    },
  });
  if (!r.ok) {
    const txt = await r.text();
    throw new Error(`App Store Connect API ${r.status} ${r.statusText} for ${path}: ${txt}`);
  }
  return r.status === 204 ? null : r.json();
}

async function findApp() {
  const data = await asc(`/v1/apps?filter[bundleId]=${encodeURIComponent(BUNDLE_ID)}&limit=1`);
  const app = data?.data?.[0];
  if (!app) throw new Error(`No app found for bundle id ${BUNDLE_ID}`);
  return app.id;
}

async function findBuild(appId) {
  const params = new URLSearchParams({
    'filter[app]': appId,
    'filter[preReleaseVersion.version]': VERSION_STRING,
    'filter[version]': BUILD_NUMBER,
    limit: '1',
  });
  const data = await asc(`/v1/builds?${params}`);
  return data?.data?.[0];
}

async function setLocalization(buildId) {
  const body = {
    data: {
      type: 'betaBuildLocalizations',
      attributes: { locale: 'en-US', whatsNew: NOTES },
      relationships: { build: { data: { type: 'builds', id: buildId } } },
    },
  };
  await asc('/v1/betaBuildLocalizations', {
    method: 'POST',
    body: JSON.stringify(body),
  });
}

async function main() {
  console.log(`▸ Looking up app ${BUNDLE_ID}…`);
  const appId = await findApp();

  console.log(`▸ Polling for build ${VERSION_STRING}+${BUILD_NUMBER} (up to ~20 min)…`);
  const maxTries = 40;
  const delayMs = 30_000;
  let build = null;
  for (let i = 0; i < maxTries; i++) {
    build = await findBuild(appId);
    if (build) break;
    process.stdout.write('.');
    await new Promise((r) => setTimeout(r, delayMs));
  }
  process.stdout.write('\n');
  if (!build) {
    console.error('Build never appeared in App Store Connect within the polling window.');
    console.error('It may still arrive later — set notes manually via App Store Connect UI.');
    process.exit(1);
  }

  console.log(`▸ Build ${build.id} found. Attaching whatsNew (${NOTES.length} chars)…`);
  await setLocalization(build.id);
  console.log('✅ TestFlight "What\'s New" set for build', BUILD_NUMBER);
}

main().catch((err) => {
  console.error('set-testflight-notes failed:', err.message);
  process.exit(1);
});
