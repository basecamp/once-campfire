import type { FastifyInstance } from 'fastify';
import { decodeRailsMessageUnsafe, signRailsMessage, verifyRailsMessage } from './rails-signed-message.js';

const MENTION_TOKEN_PURPOSE = 'attachable';
const LEGACY_MENTION_TOKEN_PURPOSE = 'mentionable';
const GLOBAL_ID_APP = 'campfire';

type MentionPayload = {
  model: 'User';
  id: string;
};

export async function signMentionSgid(_app: FastifyInstance, userId: string) {
  // Rails attachables are signed Global IDs, e.g. gid://campfire/User/:id
  return signRailsMessage(`gid://${GLOBAL_ID_APP}/User/${userId}`, {
    purpose: MENTION_TOKEN_PURPOSE
  });
}

function userIdFromGid(value: string) {
  const match = value.match(/^gid:\/\/[^/]+\/User\/([^/?#]+)$/i);
  return match?.[1] ? decodeURIComponent(match[1]) : null;
}

function extractMentionUserId(payload: unknown) {
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
    const value = payload as { id?: unknown; model?: unknown };
    if (value.model === 'User' && typeof value.id === 'string') {
      const id = value.id.trim();
      if (id) {
        return id;
      }
    }
  }

  return null;
}

export function verifyMentionSgid(app: FastifyInstance, sgid: string) {
  const verified = verifyRailsMessage<MentionPayload>(sgid, { purpose: MENTION_TOKEN_PURPOSE });
  const verifiedId = extractMentionUserId(verified);
  if (verifiedId) {
    return verifiedId;
  }

  // Unsafe decode fallback to ease transition from mixed token formats.
  const unsafe = decodeRailsMessageUnsafe<MentionPayload>(sgid, { purpose: MENTION_TOKEN_PURPOSE });
  const unsafeId = extractMentionUserId(unsafe);
  if (unsafeId) {
    return unsafeId;
  }

  // Legacy JWT token compatibility.
  try {
    const payload = app.jwt.verify<{ sub?: string; purpose?: string }>(sgid);
    if (typeof payload === 'string' || payload.purpose !== LEGACY_MENTION_TOKEN_PURPOSE || !payload.sub) {
      return null;
    }

    return payload.sub;
  } catch {
    return null;
  }
}
