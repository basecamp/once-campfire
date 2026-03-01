import { createHmac, timingSafeEqual } from 'node:crypto';
import { env } from '../config/env.js';

type RailsEnvelope = {
  _rails?: {
    message?: string;
    data?: unknown;
    exp?: string | null;
    pur?: string | null;
  };
};

type SignRailsMessageOptions = {
  purpose: string;
  expiresInSeconds?: number;
};

type VerifyRailsMessageOptions = {
  purpose: string;
  allowExpired?: boolean;
};

function hmacDigest(payload: string) {
  return createHmac('sha1', env.JWT_SECRET).update(payload).digest('hex');
}

function secureHexEqual(left: string, right: string) {
  if (left.length !== right.length) {
    return false;
  }

  try {
    return timingSafeEqual(Buffer.from(left, 'utf8'), Buffer.from(right, 'utf8'));
  } catch {
    return false;
  }
}

function toBase64(value: string) {
  return Buffer.from(value, 'utf8').toString('base64');
}

function normalizeBase64(base64Value: string) {
  const normalized = base64Value.replace(/-/g, '+').replace(/_/g, '/').replace(/\s+/g, '');
  const mod = normalized.length % 4;
  if (mod === 0) {
    return normalized;
  }
  return `${normalized}${'='.repeat(4 - mod)}`;
}

function decodeBase64ToBuffer(base64Value: string) {
  try {
    return Buffer.from(normalizeBase64(base64Value), 'base64');
  } catch {
    return null;
  }
}

function fromBase64(base64Value: string) {
  const decoded = decodeBase64ToBuffer(base64Value);
  return decoded ? decoded.toString('utf8') : null;
}

function parseMarshalTinyString(buffer: Buffer) {
  // Minimal support for Ruby Marshal strings: "\x04\bI\"\nrooms\x06:\x06ET"
  // This is enough to decode stream names from signed turbo stream tokens.
  if (buffer.length < 6 || buffer[0] !== 0x04 || buffer[1] !== 0x08) {
    return null;
  }

  const marker = buffer.indexOf(Buffer.from([0x49, 0x22]));
  if (marker < 0 || marker + 2 >= buffer.length) {
    return null;
  }

  const lengthToken = buffer[marker + 2] ?? 0;
  if (lengthToken < 6 || lengthToken > 127) {
    return null;
  }

  const length = lengthToken - 5;
  const start = marker + 3;
  const end = start + length;
  if (end > buffer.length) {
    return null;
  }

  const value = buffer.subarray(start, end).toString('utf8');
  return value || null;
}

function decodeMessageValue(encodedMessage: string): unknown {
  const rawBuffer = decodeBase64ToBuffer(encodedMessage);
  if (!rawBuffer) {
    return null;
  }
  const utf8 = rawBuffer.toString('utf8');

  try {
    return JSON.parse(utf8) as unknown;
  } catch {
    // continue
  }

  const marshalString = parseMarshalTinyString(rawBuffer);
  if (marshalString) {
    return marshalString;
  }

  const trimmed = utf8.trim();
  if (!trimmed) {
    return null;
  }

  if ((trimmed.startsWith('"') && trimmed.endsWith('"')) || (trimmed.startsWith("'") && trimmed.endsWith("'"))) {
    return trimmed.slice(1, -1);
  }

  return trimmed;
}

function decodeDataValue(data: unknown) {
  if (typeof data !== 'string') {
    return data;
  }

  const trimmed = data.trim();
  if (!trimmed) {
    return '';
  }

  try {
    return JSON.parse(trimmed) as unknown;
  } catch {
    return trimmed;
  }
}

function parseEnvelope(encodedEnvelope: string) {
  let envelope: RailsEnvelope;
  const decodedEnvelope = fromBase64(encodedEnvelope);
  if (!decodedEnvelope) {
    return null;
  }

  try {
    envelope = JSON.parse(decodedEnvelope) as RailsEnvelope;
  } catch {
    return null;
  }

  if (!envelope || typeof envelope !== 'object') {
    return null;
  }

  const railsPayload = envelope._rails;
  if (!railsPayload || typeof railsPayload !== 'object') {
    return null;
  }

  const encodedMessage = typeof railsPayload.message === 'string' ? railsPayload.message : null;
  const rawData = Object.prototype.hasOwnProperty.call(railsPayload, 'data') ? railsPayload.data : undefined;
  const purpose = typeof railsPayload.pur === 'string' ? railsPayload.pur : null;
  const expiresAt = railsPayload.exp === null || typeof railsPayload.exp === 'string' ? railsPayload.exp : null;

  if (!encodedMessage && typeof rawData === 'undefined') {
    return null;
  }

  return {
    encodedMessage,
    rawData,
    purpose,
    expiresAt
  };
}

function extractSignedParts(token: string) {
  const separatorIndex = token.lastIndexOf('--');
  if (separatorIndex <= 0) {
    return null;
  }

  return {
    encodedEnvelope: token.slice(0, separatorIndex),
    signature: token.slice(separatorIndex + 2)
  };
}

function verifyEnvelope(
  token: string,
  { purpose, allowExpired = false }: VerifyRailsMessageOptions,
  verifySignature: boolean
) {
  const parts = extractSignedParts(token);
  if (!parts) {
    return null;
  }

  if (verifySignature) {
    const expectedSignature = hmacDigest(parts.encodedEnvelope);
    if (!secureHexEqual(expectedSignature, parts.signature)) {
      return null;
    }
  }

  const parsed = parseEnvelope(parts.encodedEnvelope);
  if (!parsed || parsed.purpose !== purpose) {
    return null;
  }

  if (!allowExpired && parsed.expiresAt) {
    const expiresAtMs = Date.parse(parsed.expiresAt);
    if (Number.isFinite(expiresAtMs) && Date.now() > expiresAtMs) {
      return null;
    }
  }

  if (parsed.encodedMessage) {
    return decodeMessageValue(parsed.encodedMessage);
  }

  return decodeDataValue(parsed.rawData);
}

export function signRailsMessage(message: unknown, { purpose, expiresInSeconds }: SignRailsMessageOptions) {
  const now = Date.now();
  const expiresAt =
    typeof expiresInSeconds === 'number' && expiresInSeconds > 0
      ? new Date(now + expiresInSeconds * 1000).toISOString()
      : null;

  const serializedMessage = JSON.stringify(message);
  const envelope: RailsEnvelope = {
    _rails: {
      message: toBase64(serializedMessage),
      exp: expiresAt,
      pur: purpose
    }
  };

  const encodedEnvelope = toBase64(JSON.stringify(envelope));
  const signature = hmacDigest(encodedEnvelope);
  return `${encodedEnvelope}--${signature}`;
}

export function verifyRailsMessage<T = unknown>(token: string, options: VerifyRailsMessageOptions) {
  return verifyEnvelope(token, options, true) as T | null;
}

export function decodeRailsMessageUnsafe<T = unknown>(token: string, options: VerifyRailsMessageOptions) {
  return verifyEnvelope(token, { ...options, allowExpired: true }, false) as T | null;
}
