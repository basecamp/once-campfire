import type { FastifyPluginAsync } from 'fastify';
import { UserModel } from '../models/user.model.js';

const usersRoutes: FastifyPluginAsync = async (app) => {
  app.get('/', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const { query } = request.query as { query?: string };
    const normalized = query?.trim();

    const filter = normalized
      ? {
          name: { $regex: normalized.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), $options: 'i' },
          _id: { $ne: userId }
        }
      : {
          _id: { $ne: userId }
        };

    const finalUsers = await UserModel.find(filter, { name: 1, emailAddress: 1, status: 1 })
      .sort({ name: 1 })
      .limit(25)
      .lean();

    return {
      users: finalUsers.map((user) => ({
        id: String(user._id),
        name: user.name,
        emailAddress: user.emailAddress,
        status: user.status
      }))
    };
  });
};

export default usersRoutes;
