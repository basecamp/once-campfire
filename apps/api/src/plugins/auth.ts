import fp from 'fastify-plugin';
import cookie from '@fastify/cookie';
import jwt from '@fastify/jwt';
import type { FastifyReply, FastifyRequest } from 'fastify';
import { env } from '../config/env.js';
import { UserModel } from '../models/user.model.js';
import { refreshSessionIfNeeded } from '../services/session-auth.js';

const COOKIE_NAME = 'campfire_token';

async function authPlugin(app: import('fastify').FastifyInstance) {
  await app.register(cookie);

  await app.register(jwt, {
    secret: env.JWT_SECRET,
    cookie: {
      cookieName: COOKIE_NAME,
      signed: false
    }
  });

  app.decorate('authenticate', async (request: FastifyRequest, reply: FastifyReply) => {
    try {
      const payload = await request.jwtVerify<{ sub: string; sid: string }>();
      if (!payload.sid) {
        await reply.code(401).send({ error: 'Unauthorized' });
        return;
      }

      const session = await refreshSessionIfNeeded(
        payload.sid,
        request.headers['user-agent'] ?? '',
        request.ip
      );

      if (!session || String(session.userId) !== payload.sub) {
        await reply.code(401).send({ error: 'Unauthorized' });
        return;
      }

      const user = await UserModel.findById(payload.sub, { status: 1 }).lean();
      if (!user || user.status !== 'active') {
        await reply.code(401).send({ error: 'Unauthorized' });
        return;
      }

      request.authUserId = payload.sub;
      request.authSessionId = payload.sid;
    } catch {
      await reply.code(401).send({ error: 'Unauthorized' });
    }
  });
}

export { COOKIE_NAME };

export default fp(authPlugin, {
  name: 'auth'
});
