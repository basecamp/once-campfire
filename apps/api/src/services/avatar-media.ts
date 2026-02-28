import type { FastifyInstance } from 'fastify';
import { signAvatarId } from './avatar-token.js';

const AVATAR_COLORS = [
  '#AF2E1B',
  '#CC6324',
  '#3B4B59',
  '#BFA07A',
  '#ED8008',
  '#ED3F1C',
  '#BF1B1B',
  '#736B1E',
  '#D07B53',
  '#736356',
  '#AD1D1D',
  '#BF7C2A',
  '#C09C6F',
  '#698F9C',
  '#7C956B',
  '#5D618F',
  '#3B3633',
  '#67695E'
] as const;

const CRC32_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let index = 0; index < 256; index += 1) {
    let value = index;
    for (let shift = 0; shift < 8; shift += 1) {
      value = (value & 1) === 1 ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
    }
    table[index] = value >>> 0;
  }
  return table;
})();

function crc32(input: string) {
  let crc = 0xffffffff;
  const buffer = Buffer.from(input);
  for (const byte of buffer) {
    crc = CRC32_TABLE[(crc ^ byte) & 0xff] ^ (crc >>> 8);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

export function toRailsNumberTimestamp(value?: Date | null) {
  const date = value ?? new Date(0);
  const year = String(date.getUTCFullYear()).padStart(4, '0');
  const month = String(date.getUTCMonth() + 1).padStart(2, '0');
  const day = String(date.getUTCDate()).padStart(2, '0');
  const hour = String(date.getUTCHours()).padStart(2, '0');
  const minute = String(date.getUTCMinutes()).padStart(2, '0');
  const second = String(date.getUTCSeconds()).padStart(2, '0');
  return `${year}${month}${day}${hour}${minute}${second}`;
}

export async function buildUserAvatarPath(
  app: FastifyInstance,
  user: { _id: unknown; updatedAt?: Date | null }
) {
  const avatarId = await signAvatarId(app, String(user._id));
  const version = toRailsNumberTimestamp(user.updatedAt);
  return `/users/${avatarId}/avatar?v=${version}`;
}

export function buildAccountLogoPath(account: { updatedAt?: Date | null } | null, size?: 'small' | 'large') {
  const version = toRailsNumberTimestamp(account?.updatedAt);
  const params = new URLSearchParams({ v: version });
  if (size === 'small') {
    params.set('size', 'small');
  }

  return `/account/logo?${params.toString()}`;
}

export function userInitials(name: string) {
  const initials = name.match(/\b\w/g)?.join('').toUpperCase();
  return initials || 'U';
}

export function avatarBackgroundColor(seed: string) {
  return AVATAR_COLORS[crc32(seed) % AVATAR_COLORS.length];
}

export function renderInitialsAvatarSvg(name: string, seed: string) {
  const initials = userInitials(name);
  const textLength = initials.length >= 3 ? ' textLength="85%" lengthAdjust="spacingAndGlyphs"' : '';
  const color = avatarBackgroundColor(seed);

  return `<svg version="1.1" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" class="avatar" aria-hidden="true"><g><rect width="100%" height="100%" rx="50" fill="${color}" /><text x="50%" y="50%" fill="#FFFFFF" text-anchor="middle" dy="0.35em"${textLength} font-family="-apple-system, BlinkMacSystemFont, Segoe UI, Roboto, Helvetica, Arial, sans-serif" font-size="230" font-weight="800" letter-spacing="-5">${initials}</text></g></svg>`;
}
