import type { FastifyPluginAsync } from 'fastify';
import { asObjectId } from '../lib/object-id.js';
import { MembershipModel } from '../models/membership.model.js';
import { UserModel } from '../models/user.model.js';
import { buildUserAvatarPath } from '../services/avatar-media.js';
import { signMentionSgid } from '../services/mention-token.js';

function escapeRegex(input: string) {
  return input.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

const autocompletableRoutes: FastifyPluginAsync = async (app) => {
  app.get('/autocompletable/users', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const { query, room_id } = request.query as { query?: string; room_id?: string };

    let candidateIds: string[] | null = null;

    if (room_id) {
      const roomObjectId = asObjectId(room_id);
      if (!roomObjectId) {
        return reply.code(400).send({ error: 'Invalid room id' });
      }

      const membership = await MembershipModel.findOne({ roomId: roomObjectId, userId }).lean();
      if (!membership) {
        return reply.code(403).send({ error: 'You are not a room member' });
      }

      const memberships = await MembershipModel.find({ roomId: roomObjectId }, { userId: 1 }).lean();
      candidateIds = memberships.map((item) => String(item.userId));
    }

    const filter: Record<string, unknown> = {
      status: 'active'
    };

    if (candidateIds) {
      filter._id = { $in: candidateIds };
    }

    const normalized = query?.trim();
    if (normalized) {
      filter.name = { $regex: escapeRegex(normalized), $options: 'i' };
    }

    const users = await UserModel.find(filter, { name: 1, avatar: 1, avatarUrl: 1, status: 1, updatedAt: 1 })
      .sort({ name: 1 })
      .limit(20)
      .lean();

    const serializedUsers = await Promise.all(
      users.map(async (user) => {
        const id = String(user._id);
        const avatarPath = await buildUserAvatarPath(app, user);
        const sgid = await signMentionSgid(app, id);
        return {
          id,
          value: id,
          name: user.name,
          avatarUrl: avatarPath,
          avatar_url: avatarPath,
          sgid,
          status: user.status
        };
      })
    );

    const path = request.raw.url ?? request.url ?? '';
    const apiRequest = path.startsWith('/api/');

    if (apiRequest) {
      return { users: serializedUsers };
    }

    return serializedUsers;
  });
};

export default autocompletableRoutes;
