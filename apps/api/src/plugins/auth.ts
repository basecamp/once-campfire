import fp from 'fastify-plugin';
import cookie from '@fastify/cookie';
import jwt from '@fastify/jwt';
import type { FastifyReply, FastifyRequest } from 'fastify';
import { env } from '../config/env.js';
import { UserModel } from '../models/user.model.js';
import { refreshSessionIfNeeded } from '../services/session-auth.js';

const COOKIE_NAME = 'session_token';
const AUTH_COOKIE_MAX_AGE_SECONDS = 60 * 60 * 24 * 365 * 20;

function readSignedSessionToken(request: FastifyRequest) {
  const raw = request.cookies[COOKIE_NAME];
  if (!raw) {
    return null;
  }

  const unsigned = request.unsignCookie(raw);
  if (unsigned.valid) {
    return unsigned.value;
  }

  // Backward compatibility for previously unsigned cookies.
  if (!raw.startsWith('s:')) {
    return raw;
  }

  return null;
}

function authCookieOptions() {
  return {
    path: '/',
    httpOnly: true,
    sameSite: 'lax' as const,
    secure: false,
    signed: true,
    maxAge: AUTH_COOKIE_MAX_AGE_SECONDS
  };
}

export function setAuthCookie(reply: FastifyReply, sessionToken: string) {
  reply.setCookie(COOKIE_NAME, sessionToken, authCookieOptions());
}

export function clearAuthCookie(reply: FastifyReply) {
  reply.clearCookie(COOKIE_NAME, { path: '/' });
}

async function authPlugin(app: import('fastify').FastifyInstance) {
  await app.register(cookie, {
    secret: env.JWT_SECRET
  });

  await app.register(jwt, {
    secret: env.JWT_SECRET
  });

  async function resolveAuthContext(request: FastifyRequest) {
    const sessionToken = readSignedSessionToken(request);
    if (!sessionToken) {
      return null;
    }

    const session = await refreshSessionIfNeeded(sessionToken, request.headers['user-agent'] ?? '', request.ip);
    if (!session) {
      return null;
    }

    const userId = String(session.userId);
    const user = await UserModel.findById(userId, { status: 1 }).lean();
    if (!user || user.status !== 'active') {
      return null;
    }

    return {
      userId,
      sessionId: String(session._id)
    };
  }

  app.decorate('authenticate', async (request: FastifyRequest, reply: FastifyReply) => {
    const auth = await resolveAuthContext(request);
    if (!auth) {
      await reply.code(401).send({ error: 'Unauthorized' });
      return;
    }

    request.authUserId = auth.userId;
    request.authSessionId = auth.sessionId;
  });

  app.decorate('tryAuthenticate', async (request: FastifyRequest) => {
    const auth = await resolveAuthContext(request);
    if (!auth) {
      return null;
    }

    request.authUserId = auth.userId;
    request.authSessionId = auth.sessionId;

    return auth;
  });
}

export { COOKIE_NAME };

export default fp(authPlugin, {
  name: 'auth'
});
