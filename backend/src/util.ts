import { customAlphabet } from 'nanoid';

const alphabet = '0123456789abcdefghijklmnopqrstuvwxyz';
export const newId = customAlphabet(alphabet, 16);
export const newInviteCode = customAlphabet('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 8);

export const now = () => Math.floor(Date.now() / 1000);

const USERNAME_RE = /^[a-z0-9_]{3,24}$/;
export function validUsername(s: string): boolean {
  return USERNAME_RE.test(s);
}

export function slugifyEmailToUsername(email: string): string {
  const local = email.split('@')[0] ?? 'user';
  const base = local.toLowerCase().replace(/[^a-z0-9_]/g, '_').slice(0, 20);
  return base.length >= 3 ? base : `${base}_user`;
}
