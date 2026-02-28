import type { FastifyPluginAsync } from 'fastify';
import { BanModel } from '../models/ban.model.js';
import { SessionModel } from '../models/session.model.js';
import { UserModel } from '../models/user.model.js';
import { enqueueRemoveBannedContentJob } from '../queues/moderation.queue.js';
import { disconnectUser } from '../realtime/connection-manager.js';
import { isPublicIpAddress, normalizeIpAddress } from '../services/ip-address.js';

async function ensureAdmin(actorId: string) {
  const actor = await UserModel.findById(actorId, { role: 1 }).lean();
  return actor?.role === 'admin';
}

const moderationRoutes: FastifyPluginAsync = async (app) => {
  app.post('/users/:userId/ban', { preHandler: app.authenticate }, async (request, reply) => {
    const actorId = request.authUserId;
    if (!actorId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    if (!(await ensureAdmin(actorId))) {
      return reply.code(403).send({ error: 'Forbidden' });
    }

    const { userId } = request.params as { userId: string };

    const user = await UserModel.findById(userId).lean();
    if (!user) {
      return reply.code(404).send({ error: 'User not found' });
    }

    const sessions = await SessionModel.find({ userId }, { ipAddress: 1 }).lean();
    const ips = Array.from(
      new Set(
        sessions
          .map((session) => normalizeIpAddress(session.ipAddress))
          .filter((ip): ip is string => Boolean(ip && isPublicIpAddress(ip)))
      )
    );

    if (ips.length > 0) {
      await BanModel.insertMany(
        ips.map((ipAddress) => ({ userId, ipAddress })),
        { ordered: false }
      ).catch(() => {
        // Ignore duplicates.
      });
    }

    await Promise.all([
      UserModel.updateOne({ _id: userId }, { $set: { status: 'banned' } }),
      SessionModel.deleteMany({ userId })
    ]);

    disconnectUser(userId, {
      reason: 'banned',
      reconnect: false
    });

    await enqueueRemoveBannedContentJob(userId);

    return { ok: true };
  });

  app.delete('/users/:userId/ban', { preHandler: app.authenticate }, async (request, reply) => {
    const actorId = request.authUserId;
    if (!actorId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    if (!(await ensureAdmin(actorId))) {
      return reply.code(403).send({ error: 'Forbidden' });
    }

    const { userId } = request.params as { userId: string };

    const user = await UserModel.findById(userId).lean();
    if (!user) {
      return reply.code(404).send({ error: 'User not found' });
    }

    await Promise.all([
      BanModel.deleteMany({ userId }),
      UserModel.updateOne({ _id: userId }, { $set: { status: 'active' } })
    ]);

    return { ok: true };
  });
};

export default moderationRoutes;
