import bcrypt from 'bcryptjs';
import type { FastifyPluginAsync } from 'fastify';
import { z } from 'zod';
import { COOKIE_NAME } from '../plugins/auth.js';
import { PushSubscriptionModel } from '../models/push-subscription.model.js';
import { SessionModel } from '../models/session.model.js';
import { UserModel } from '../models/user.model.js';
import { createSession } from '../services/session-auth.js';

const SESSION_CREATE_LIMIT = 10;
const SESSION_CREATE_WINDOW_MS = 3 * 60 * 1000;
const sessionCreateAttempts = new Map<string, { count: number; resetAt: number }>();

const createSessionSchema = z.object({
  emailAddress: z.string().email(),
  password: z.string().min(8).max(128),
  pushSubscriptionEndpoint: z.string().url().optional()
});

function parseSessionPayload(input: unknown) {
  if (!input || typeof input !== 'object') {
    return createSessionSchema.parse(input);
  }

  const payload = input as {
    emailAddress?: unknown;
    email_address?: unknown;
    password?: unknown;
    pushSubscriptionEndpoint?: unknown;
    push_subscription_endpoint?: unknown;
  };

  return createSessionSchema.parse({
    emailAddress:
      (typeof payload.emailAddress === 'string' ? payload.emailAddress : undefined) ??
      (typeof payload.email_address === 'string' ? payload.email_address : undefined),
    password: typeof payload.password === 'string' ? payload.password : undefined,
    pushSubscriptionEndpoint:
      (typeof payload.pushSubscriptionEndpoint === 'string' ? payload.pushSubscriptionEndpoint : undefined) ??
      (typeof payload.push_subscription_endpoint === 'string' ? payload.push_subscription_endpoint : undefined)
  });
}

function consumeSessionAttempt(ipAddress: string) {
  const now = Date.now();
  const key = ipAddress || 'unknown';
  const current = sessionCreateAttempts.get(key);

  if (!current || current.resetAt <= now) {
    sessionCreateAttempts.set(key, {
      count: 1,
      resetAt: now + SESSION_CREATE_WINDOW_MS
    });
    return true;
  }

  if (current.count >= SESSION_CREATE_LIMIT) {
    return false;
  }

  current.count += 1;
  sessionCreateAttempts.set(key, current);
  return true;
}

const sessionsRoutes: FastifyPluginAsync = async (app) => {
  app.get('/session/new', async () => {
    const usersCount = await UserModel.countDocuments();
    return {
      firstRunRequired: usersCount === 0,
      first_run_required: usersCount === 0
    };
  });

  app.post('/session', async (request, reply) => {
    if (!consumeSessionAttempt(request.ip)) {
      return reply.code(429).send({ error: 'Too many requests or unauthorized.' });
    }

    const payload = parseSessionPayload(request.body);

    const user = await UserModel.findOne({ emailAddress: payload.emailAddress.toLowerCase() });
    if (!user) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    if (user.status !== 'active') {
      return reply.code(403).send({ error: 'User is not active' });
    }

    const valid = await bcrypt.compare(payload.password, user.passwordHash);
    if (!valid) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const session = await createSession({
      userId: String(user._id),
      userAgent: request.headers['user-agent'] ?? '',
      ipAddress: request.ip
    });

    const token = await reply.jwtSign({ sub: String(user._id), sid: String(session._id) }, { expiresIn: '7d' });

    reply.setCookie(COOKIE_NAME, token, {
      path: '/',
      httpOnly: true,
      sameSite: 'lax',
      secure: false,
      maxAge: 60 * 60 * 24 * 7
    });

    return {
      user: {
        id: String(user._id),
        name: user.name,
        emailAddress: user.emailAddress,
        email_address: user.emailAddress,
        role: user.role,
        status: user.status,
        bio: user.bio ?? ''
      }
    };
  });

  app.delete('/session', { preHandler: app.authenticate }, async (request, reply) => {
    const endpoint =
      (request.body as { pushSubscriptionEndpoint?: string; push_subscription_endpoint?: string } | undefined)
        ?.pushSubscriptionEndpoint ??
      (request.body as { pushSubscriptionEndpoint?: string; push_subscription_endpoint?: string } | undefined)
        ?.push_subscription_endpoint;

    const userId = request.authUserId;

    await Promise.all([
      request.authSessionId ? SessionModel.deleteOne({ _id: request.authSessionId }) : Promise.resolve(),
      endpoint && userId ? PushSubscriptionModel.deleteMany({ endpoint, userId }) : Promise.resolve()
    ]);

    reply.clearCookie(COOKIE_NAME, { path: '/' });
    return reply.code(204).send();
  });
};

export default sessionsRoutes;
