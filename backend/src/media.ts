// HMAC-signed, short-lived URLs for R2 media.
// URL shape:  <api-base>/media/<scope>/<owner>/<filename>?e=<unix-ts>&s=<sig>
// Signature:  base64url(HMAC-SHA256(secret, "<key>|<expires-at>"))

import type { Env } from './types';

const DEFAULT_TTL_SEC = 3600;

export async function signMediaUrl(env: Env, key: string, baseUrl: string, ttlSec: number = DEFAULT_TTL_SEC): Promise<string> {
  const expiresAt = Math.floor(Date.now() / 1000) + ttlSec;
  const sig = await sign(env, key, expiresAt);
  return `${baseUrl}/media/${key}?e=${expiresAt}&s=${sig}`;
}

export async function verifyMediaSignature(env: Env, key: string, expiresAt: number, signature: string): Promise<boolean> {
  if (!signature || !expiresAt) return false;
  if (expiresAt < Math.floor(Date.now() / 1000)) return false;
  const expected = await sign(env, key, expiresAt);
  return timingSafeEqual(expected, signature);
}

async function sign(env: Env, key: string, expiresAt: number): Promise<string> {
  if (!env.MEDIA_SIGNING_SECRET) {
    throw new Error('MEDIA_SIGNING_SECRET is not set');
  }
  const enc = new TextEncoder();
  const cryptoKey = await crypto.subtle.importKey(
    'raw',
    enc.encode(env.MEDIA_SIGNING_SECRET),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const sigBytes = await crypto.subtle.sign('HMAC', cryptoKey, enc.encode(`${key}|${expiresAt}`));
  return base64UrlEncode(new Uint8Array(sigBytes));
}

function base64UrlEncode(bytes: Uint8Array): string {
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
