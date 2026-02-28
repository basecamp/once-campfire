import type { FastifyPluginAsync } from 'fastify';
import { COOKIE_NAME } from '../plugins/auth.js';
import { UserModel } from '../models/user.model.js';
import { createSession } from '../services/session-auth.js';
import { verifyTransferId } from '../services/transfer-token.js';

const sessionTransfersRoutes: FastifyPluginAsync = async (app) => {
  app.get('/session/transfers/:id', async (request, reply) => {
    const { id } = request.params as { id: string };
    const userId = verifyTransferId(app, id);

    if (!userId) {
      return reply.code(400).send({ valid: false });
    }

    const user = await UserModel.findOne({
      _id: userId,
      status: 'active'
    }).lean();

    if (!user) {
      return reply.code(400).send({ valid: false });
    }

    return { valid: true };
  });

  app.patch('/session/transfers/:id', async (request, reply) => {
    const { id } = request.params as { id: string };
    const userId = verifyTransferId(app, id);

    if (!userId) {
      return reply.code(400).send({ error: 'Invalid transfer id' });
    }

    const user = await UserModel.findOne({
      _id: userId,
      status: 'active'
    });

    if (!user) {
      return reply.code(400).send({ error: 'Invalid transfer id' });
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

    return { ok: true };
  });
};

export default sessionTransfersRoutes;
