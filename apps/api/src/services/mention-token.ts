import type { FastifyInstance } from 'fastify';

const MENTION_TOKEN_PURPOSE = 'mentionable';

type MentionPayload = {
  sub: string;
  purpose: string;
};

export async function signMentionSgid(app: FastifyInstance, userId: string) {
  return app.jwt.sign({
    sub: userId,
    purpose: MENTION_TOKEN_PURPOSE
  });
}

export function verifyMentionSgid(app: FastifyInstance, sgid: string) {
  try {
    const payload = app.jwt.verify<MentionPayload>(sgid);
    if (typeof payload === 'string' || payload.purpose !== MENTION_TOKEN_PURPOSE || !payload.sub) {
      return null;
    }

    return payload.sub;
  } catch {
    return null;
  }
}
