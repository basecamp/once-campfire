import type { FastifyInstance } from 'fastify';
import { signRailsMessage, verifyRailsMessage } from './rails-signed-message.js';

const TRANSFER_TOKEN_PURPOSE = 'transfer';
const TRANSFER_TOKEN_EXPIRY_SECONDS = 4 * 60 * 60;

type TransferPayload = {
  model: 'User';
  id: string;
};

function userIdFromGid(value: string) {
  const match = value.match(/^gid:\/\/[^/]+\/User\/([^/?#]+)$/i);
  return match?.[1] ? decodeURIComponent(match[1]) : null;
}

function extractTransferUserId(payload: unknown) {
  if (!payload) {
    return null;
  }

  if (typeof payload === 'string') {
    const value = payload.trim();
    if (!value) {
      return null;
    }

    const gidId = userIdFromGid(value);
    return gidId ?? value;
  }

  if (typeof payload === 'object') {
    const value = payload as { model?: unknown; id?: unknown };
    if (value.model === 'User' && typeof value.id === 'string') {
      const id = value.id.trim();
      if (id) {
        return id;
      }
    }
  }

  return null;
}

export async function signTransferId(_app: FastifyInstance, userId: string) {
  return signRailsMessage(userId, {
    purpose: TRANSFER_TOKEN_PURPOSE,
    expiresInSeconds: TRANSFER_TOKEN_EXPIRY_SECONDS
  });
}

export function verifyTransferId(app: FastifyInstance, transferId: string) {
  const verified = verifyRailsMessage<TransferPayload>(transferId, { purpose: TRANSFER_TOKEN_PURPOSE });
  const verifiedId = extractTransferUserId(verified);
  if (verifiedId) {
    return verifiedId;
  }

  // Legacy JWT transfer tokens.
  try {
    const payload = app.jwt.verify<{ sub?: string; purpose?: string }>(transferId);
    if (typeof payload === 'string' || payload.purpose !== TRANSFER_TOKEN_PURPOSE || !payload.sub) {
      return null;
    }

    return payload.sub;
  } catch {
    return null;
  }
}
