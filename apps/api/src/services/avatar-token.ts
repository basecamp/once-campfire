import type { FastifyInstance } from 'fastify';

const AVATAR_TOKEN_PURPOSE = 'avatar';

type AvatarPayload = {
  sub: string;
  purpose: string;
};

export async function signAvatarId(app: FastifyInstance, userId: string) {
  return app.jwt.sign({
    sub: userId,
    purpose: AVATAR_TOKEN_PURPOSE
  });
}

export function verifyAvatarId(app: FastifyInstance, avatarId: string) {
  try {
    const payload = app.jwt.verify<AvatarPayload>(avatarId);
    if (typeof payload === 'string' || payload.purpose !== AVATAR_TOKEN_PURPOSE || !payload.sub) {
      return null;
    }

    return payload.sub;
  } catch {
    return null;
  }
}
