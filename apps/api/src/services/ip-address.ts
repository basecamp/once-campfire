import { isIP } from 'node:net';

export function normalizeIpAddress(value: unknown) {
  if (typeof value !== 'string') {
    return null;
  }

  let ip = value.trim();
  if (!ip) {
    return null;
  }

  if (ip.includes(',')) {
    ip = ip.split(',')[0]?.trim() ?? '';
  }

  if (ip.startsWith('[') && ip.endsWith(']')) {
    ip = ip.slice(1, -1);
  }

  const zoneIndex = ip.indexOf('%');
  if (zoneIndex >= 0) {
    ip = ip.slice(0, zoneIndex);
  }

  if (ip.startsWith('::ffff:')) {
    const mapped = ip.slice(7);
    if (isIP(mapped) === 4) {
      ip = mapped;
    }
  }

  return isIP(ip) === 0 ? null : ip.toLowerCase();
}

function isPrivateIpv4(ip: string) {
  const [a, b] = ip.split('.').map((chunk) => Number(chunk));

  return (
    a === 10 ||
    a === 127 ||
    (a === 169 && b === 254) ||
    (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 168)
  );
}

function isPrivateIpv6(ip: string) {
  return ip === '::1' || ip.startsWith('fe80:') || ip.startsWith('fc') || ip.startsWith('fd');
}

export function isPrivateIpAddress(value: unknown) {
  const ip = normalizeIpAddress(value);
  if (!ip) {
    return true;
  }

  const version = isIP(ip);
  if (version === 4) {
    return isPrivateIpv4(ip);
  }

  if (version === 6) {
    return isPrivateIpv6(ip);
  }

  return true;
}

export function isPublicIpAddress(value: unknown) {
  const ip = normalizeIpAddress(value);
  if (!ip) {
    return false;
  }

  return !isPrivateIpAddress(ip);
}
